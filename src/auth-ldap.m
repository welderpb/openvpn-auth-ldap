/*
 * auth_ldap.m vi:ts=4:sw=4:expandtab:
 * OpenVPN LDAP Authentication Plugin
 *
 * Copyright (c) 2005 - 2007 Landon Fuller <landonf@threerings.net>
 * Copyright (c) 2007 Three Rings Design, Inc.
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 * 3. Neither the name of Landon Fuller nor the names of any contributors
 *    may be used to endorse or promote products derived from this
 *    software without specific prior written permission.
 * 
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

#import <err.h>
#import <stdio.h>
#import <stdlib.h>
#import <stdarg.h>
#import <errno.h>

#import <ldap.h>

#import <openvpn-plugin.h>

#import <TRVPNPlugin.h>
#import <pthread.h>


#include "openvpn-cr.h"

/* Per-client Context (for Async) */
typedef struct per_client_ctx {
	int n_calls;
	bool generated_pf_file;
} per_client_ctx;


/* Plugin Context */
typedef struct ldap_ctx {
    TRAuthLDAPConfig *config;
    per_client_ctx *pcc;
    char *username;
    char *password;
    const char *acf;
    pthread_t async_auth_thread;
    pthread_mutex_t ldap_ctx_lock;
#ifdef HAVE_PF
    id<TRPacketFilter> pf;
#endif
} ldap_ctx;

static const char *get_env(const char *key, const char *env[]) {
    int i;

    if (!env)
        return (NULL);

    for (i = 0; env[i]; i++) {
        size_t keylen = strlen(key);

        if (keylen > strlen(env[i]))
            continue;

        if (!strncmp(key, env[i], keylen)) {
            const char *p = env[i] + keylen;
            if (*p == '=')
                return (p + 1);
        }
    }

    return (NULL);
}

static TRString *quoteForSearch(const char *string) {
    const char specialChars[] = "*()\\"; /* RFC 2254. We don't care about NULL */
    TRString *result = [[TRString alloc] init];
    TRString *unquotedString, *part;
    TRAutoreleasePool *pool = [[TRAutoreleasePool alloc] init];

    /* Make a copy of the string */
    unquotedString = [[TRString alloc] initWithCString: string];

    /* Initialize the result */
    result = [[TRString alloc] init];

    /* Quote all occurrences of the special characters */
    while ((part = [unquotedString substringToCharset: specialChars]) != NULL) {
        TRString *temp;
        size_t index;
        char c;

        /* Append everything until the first special character */
        [result appendString: part];

        /* Append the backquote */
        [result appendCString: "\\"];

        /* Get the special character */
        index = [unquotedString indexToCharset: specialChars];
        temp = [unquotedString substringFromIndex: index];
        c = [temp charAtIndex: 0];

        /* Append it, too! */
        [result appendChar: c];

        /* Move unquotedString past the special character */
        temp = [[unquotedString substringFromCharset: specialChars] retain];

        [unquotedString release];
        unquotedString = temp;
    }

    /* Append the remainder, if any */
    if (unquotedString) {
        [result appendString: unquotedString];
        [unquotedString release];
    }

    [pool release];

    return (result);
}

static TRString *createSearchFilter(TRString *template, const char *username) {
    TRString *templateString;
    TRString *result, *part;
    TRString *quotedName;
    const char userFormat[] = "%u";
    TRAutoreleasePool *pool = [[TRAutoreleasePool alloc] init];

    /* Copy the template */
    templateString = [[[TRString alloc] initWithString: template] autorelease];

    /* Initialize the result */
    result = [[TRString alloc] init];

    /* Quote the username */
    quotedName = quoteForSearch(username);

    while ((part = [templateString substringToCString: userFormat]) != NULL) {
        TRString *temp;

        /* Append everything until the first %u */
        [result appendString: part];

        /* Append the username */
        [result appendString: quotedName];

        /* Move templateString past the %u */
        temp = [templateString substringFromCString: userFormat];
        templateString = temp;
    }

    [quotedName release];

    /* Append the remainder, if any */
    if (templateString) {
        [result appendString: templateString];
    }

    [pool release];

    return (result);
}

#ifdef HAVE_PF
static BOOL pf_open(struct ldap_ctx *ctx) {
    TRString *tableName;
    TRLDAPGroupConfig *groupConfig;
    TREnumerator *groupIter = nil;
    pferror_t pferror;

    /* Acquire a reference to /dev/pf */
    ctx->pf = [[TRLocalPacketFilter alloc] init];
    if ((pferror = [ctx->pf open]) != PF_SUCCESS) {
        /* /dev/pf could not be opened. Is it available? */
        [TRLog error: "Failed to open /dev/pf: %s", [TRPacketFilterUtil stringForError: pferror]];
        ctx->pf = nil;
        return NO;
    }

    /* Clear out all referenced PF tables */
    if ((tableName = [ctx->config pfTable])) {
        if ((pferror = [ctx->pf flushTable: tableName]) != PF_SUCCESS) {
            [TRLog error: "Failed to clear packet filter table \"%s\": %s", [tableName cString], [TRPacketFilterUtil stringForError: pferror]];
            goto error;
        }
    }

    if ([ctx->config ldapGroups]) {
        groupIter = [[ctx->config ldapGroups] objectEnumerator];
        while ((groupConfig = [groupIter nextObject]) != nil) {
            if ((tableName = [groupConfig pfTable])) {
                if ((pferror = [ctx->pf flushTable: tableName]) != PF_SUCCESS) {
                    [TRLog error: "Failed to clear packet filter table \"%s\": %s", [tableName cString], [TRPacketFilterUtil stringForError: pferror]];
                    goto error;
                }
            }
        }
	[groupIter release];
    }

    return YES;

    error:
    [ctx->pf release];
    ctx->pf = NULL;
    if(groupIter != nil)
        [groupIter release];
    return NO;
}
#endif /* HAVE_PF */

OPENVPN_EXPORT openvpn_plugin_handle_t openvpn_plugin_open_v2(
    unsigned int *type,
    const char *argv[],
    const char *envp[],
    struct openvpn_plugin_string_list **return_list)
{
    ldap_ctx *ctx = xmalloc(sizeof(ldap_ctx));

/* Read the configuration */
    ctx->config = [[TRAuthLDAPConfig alloc] initWithConfigFile: argv[1]];
    if (!ctx->config) {
        free(ctx);
        return (NULL);
    }

#ifdef HAVE_PF
    ctx->pf = NULL;
    /* Open reference to /dev/pf and clear out all of our PF tables */
    if ([ctx->config pfEnabled] && !pf_open(ctx)) {
        [ctx->config release];
        free(ctx);
        return (NULL);
    }
#endif


    *type = OPENVPN_PLUGIN_MASK(OPENVPN_PLUGIN_AUTH_USER_PASS_VERIFY) |
        OPENVPN_PLUGIN_MASK(OPENVPN_PLUGIN_CLIENT_CONNECT) |
        OPENVPN_PLUGIN_MASK(OPENVPN_PLUGIN_CLIENT_DISCONNECT);

    return (ctx);
}

OPENVPN_EXPORT void
    openvpn_plugin_close_v1(openvpn_plugin_handle_t handle)
{
    ldap_ctx *ctx = handle;

    /* Clean up the configuration file */
    [ctx->config release];

    /* Clean up PF */
#ifdef HAVE_PF
    if (ctx->pf)
        [ctx->pf release];
#endif

    /* Finished */
    free(ctx);
}

TRLDAPConnection *connect_ldap(TRAuthLDAPConfig *config) {
    TRLDAPConnection *ldap;
    TRString *value;

    /* Initialize our LDAP Connection */
    ldap = [[TRLDAPConnection alloc] initWithURL: [config url] timeout: [config timeout]];
    if (!ldap) {
        [TRLog error: "Unable to open LDAP connection to %s\n", [[config url] cString]];
        return nil;
    }

    /* Referrals */
    if ([config referralEnabled]) {
        if (![ldap setReferralEnabled: YES])
            goto error;
    } else {
        if (![ldap setReferralEnabled: NO])
            goto error;
    }

    /* Certificate file */
    if ((value = [config tlsCACertFile])) 
        if (![ldap setTLSCACertFile: value])
            goto error;

    /* Certificate directory */
    if ((value = [config tlsCACertDir])) 
        if (![ldap setTLSCACertDir: value])
            goto error;

    /* Client Certificate Pair */
    if ([config tlsCertFile] && [config tlsKeyFile])
        if(![ldap setTLSClientCert: [config tlsCertFile] keyFile: [config tlsKeyFile]])
            goto error;

    /* Cipher suite */
    if ((value = [config tlsCipherSuite]))
        if(![ldap setTLSCipherSuite: value])
            goto error;

    /* Start TLS */
    if ([config tlsEnabled])
        if (![ldap startTLS])
            goto error;

    /* Bind if requested */
    if ([config bindDN]) {
        if (![ldap bindWithDN: [config bindDN] password: [config bindPassword]]) {
            [TRLog error: "Unable to bind as %s", [[config bindDN] cString]];
            goto error;
        }
    }

    return ldap;

    error:
    [ldap release];
    return nil;
}

static TRLDAPEntry *find_ldap_user (TRLDAPConnection *ldap, TRAuthLDAPConfig *config, const char *username) {
    TRString		*searchFilter;
    TRArray			*ldapEntries;
    TRLDAPEntry		*result = nil;

    /* Assemble our search filter */
    [TRLog debug: "Generating a search filter for \"%s\".", username];
    searchFilter = createSearchFilter([config searchFilter], username);

    /* Search! */
    [TRLog debug: "Locating LDAP entries."];
    ldapEntries = [ldap searchWithFilter: searchFilter
        scope: LDAP_SCOPE_SUBTREE
        baseDN: [config baseDN]
        attributes: NULL];

    [searchFilter release];

    if (!ldapEntries)
        return nil;
    if ([ldapEntries count] < 1) {
        return nil;
    }

    /* The specified search string may (but should not) return more than one entry.
     * We ignore any extras. */
    result = [[ldapEntries lastObject] retain];

    return result;
}


static BOOL auth_ldap_user(TRLDAPConnection *ldap, TRAuthLDAPConfig *config, TRLDAPEntry *ldapUser, const char *password) {
    TRLDAPConnection *authConn;
    TRString *passwordString;
    BOOL result = NO;

    /* Create a second connection for binding */
    authConn = connect_ldap(config);
    if (!authConn) {
        return NO;
    }
    
    /* Allocate the string to pass to bindWithDN */
    passwordString = [[TRString alloc] initWithCString: password];
    
    if ([authConn bindWithDN: [ldapUser dn] password: passwordString]) {
        result = YES;
    }

    [TRLog debug: "authConn bindWithDN result: %d", result];

    [passwordString release];
    [authConn release];

    return result;
}

static TRArray *find_ldap_group(TRLDAPConnection *ldap, TRAuthLDAPConfig *config, TRLDAPEntry *ldapUser) {
    TREnumerator *groupIter;
    TRArray *resultGroupIter;
    TRLDAPGroupConfig *groupConfig;
    TRArray *ldapEntries;
    TREnumerator *entryIter = nil;
    TRLDAPEntry *entry;
    TRLDAPGroupConfig *result = nil;
    //int userNameLength;

    /*
     * Groups are loaded into the array in the order that they are listed
     * in the configuration file, and we are expected to perform
     * "first match". Thusly, we'll walk the stack from the bottom up.
     */
    groupIter = [[config ldapGroups] objectReverseEnumerator];
    resultGroupIter = [[TRArray alloc] init];

    while ((groupConfig = [groupIter nextObject]) != nil) {

        /* Search for the group */
        ldapEntries = [ldap searchWithFilter: [groupConfig searchFilter]
            scope: LDAP_SCOPE_SUBTREE
            baseDN: [groupConfig baseDN]
            attributes: NULL];

        /* Error occured, all stop */
        if (!ldapEntries)
            continue;

        /* If RFC2307BIS flag is true, search for full DN, otherwise just search for uid */
        TRString *searchValue = [groupConfig memberRFC2307BIS] ? [ldapUser dn] : [ldapUser rdn];

        /* This will be used if we're using the "search" operation instead of the "compare" operation */
        TRString *searchFilter = [TRString stringWithFormat: "(%s=%s)", [[groupConfig memberAttribute] cString], [searchValue cString]];

        /* Iterate over the returned entries */
        entryIter = [ldapEntries objectEnumerator];
        while ((entry = [entryIter nextObject]) != nil) {
            if ((![groupConfig useCompareOperation] && [ldap searchWithFilter: searchFilter scope: LDAP_SCOPE_SUBTREE baseDN: [entry dn] attributes: NULL]) ||
                ([groupConfig useCompareOperation] && [ldap compareDN: [entry dn] withAttribute: [groupConfig memberAttribute] value: searchValue])) {
                /* Group match! */
		[resultGroupIter addObject: groupConfig];
                result = groupConfig;
            }
        }
	[entryIter release];

        //if (result)
            //break;
    }

    if (result)
    	return resultGroupIter;
    else {
    	[resultGroupIter release];
    	return nil;
    }

}

/** Handle user authentication. */
//static int handle_auth_user_pass_verify(ldap_ctx *ctx, per_client_ctx *pcc, const char *envp[], TRLDAPConnection *ldap, TRLDAPEntry *ldapUser, const char *password) {
void *async_handle_auth_user_pass_verify(void *ctx_ptr) {
    ldap_ctx *ctx = ctx_ptr;
    TRLDAPConnection *ldap = nil;
    TRLDAPEntry *ldapUser = nil;
    TRString *userName;
    TRArray *groupConfigArray;

    bool verified = NO;

    /* Per-request allocation pool. */
    TRAutoreleasePool *pool = [[TRAutoreleasePool alloc] init];

    /* At the very least, we need a username to work with */
    if (!ctx->username) {
        [TRLog debug: "No remote username supplied to OpenVPN LDAP Plugin."];
        goto set_acf;
    }

    /* Create an LDAP connection */
    [TRLog debug: "Attempting to connect to LDAP host"];
    if (!(ldap = connect_ldap(ctx->config))) {
        [TRLog error: "LDAP connect failed."];
        goto set_acf;
    }

    /* Find the user record */
    [TRLog debug: "Locating the LDAP user for username \"%s\"", ctx->username];
    ldapUser = find_ldap_user(ldap, ctx->config, ctx->username);
    [TRLog debug: "Found LDAP DN for user: \"%s\"", [[ldapUser dn] cString]];
    userName = [[TRString alloc] initWithCString: ctx->username];
    [ldapUser setRDN: userName];

    if (!ldapUser) {
        /* No such user. */
        [TRLog warning: "LDAP user \"%s\" was not found", ctx->username];
        verified = NO;
        goto set_acf;
    }

	const char *auth_password = ctx->password;
	openvpn_response resp;
	if ([ctx->config passWordIsCR]) {
		char *parse_error;
		if (!extract_openvpn_cr(ctx->password, &resp, &parse_error)) {
	        	[TRLog error: "Error extracting challenge/response from password. Parse error = '%s'", 	parse_error];
	        	//return (OPENVPN_PLUGIN_FUNC_ERROR);
                goto set_acf;
		}
		auth_password = (const char*)resp.password;
	}

    /* Authenticate the user */
    if (!auth_ldap_user(ldap, ctx->config, ldapUser, auth_password)) {
        [TRLog error: "Incorrect password supplied for LDAP DN \"%s\".", [[ldapUser dn] cString]];
        //return (OPENVPN_PLUGIN_FUNC_ERROR);
        verified = NO;
        goto set_acf;
    }

    /* User authenticated, find group, if any */
    if ([ctx->config ldapGroups]) {
	    groupConfigArray = find_ldap_group(ldap, ctx->config, ldapUser);
	    if (!groupConfigArray && [ctx->config requireGroup]) {
            /* No group match, and group membership is required */
            verified = NO;
        } else {
	    [groupConfigArray release];
            /* Group match! */
            verified = YES;
        }
    } else {
        // No groups, user OK
        verified = YES;
    }
#ifdef HAVE_PF
    /* Grab the requested PF table name, if any */
    if (groupConfigArray) {
        TRLDAPGroupConfig *grConfig;
        groupConfigIter = [groupConfigArray objectEnumerator];
        while ((grConfig = [groupConfigIter nextObject]) != nil) {
           tableName = [grConfig pfTable];
           if (tableName)
                   pf_client_connect_disconnect(ctx, tableName, remoteAddress, connecting);
   	    }
   	    [groupConfigIter release];
   	    [groupConfigArray release];
    } else {
        tableName = [ctx->config pfTable];
	    if (tableName)
           pf_client_connect_disconnect(ctx, tableName, remoteAddress, connecting);
    }
#endif /* HAVE_PF */

set_acf:
    // Set the auth_control_file value based on success or failure.
    if (ctx->acf) {
        FILE *acf;
        acf = fopen(ctx->acf, "w");
        if (verified) {
            [TRLog debug: "\"%s\" was verified; setting acf to 1: \"%s\"", ctx->username, ctx->acf];
            fputs("1", acf);
        }
        else {
            [TRLog debug: "\"%s\" was unable to be verified; setting acf to 0: \"%s\"", ctx->username, ctx->acf];
            fputs("0", acf);
        }
        fclose(acf);
    }

    if (ldapUser != nil)
        [TRLog debug: "Releasing ldapUser"];
        [ldapUser release];

    if (ldap != nil)
        [TRLog debug: "Releasing ldap"];
        [ldap release];

    if (pool != nil) {
        [TRLog debug: "Draining pool"];
        [pool drain];
    }

    // pthread_mutex_unlock(&ctx->ldap_ctx_lock);

    // return ctx_ptr;
}

#ifdef HAVE_PF
/* Add (or remove) the remote address */
static BOOL pf_client_connect_disconnect(struct ldap_ctx *ctx, TRString *tableName, const char *remoteAddress, BOOL connecting) {
    TRString *addressString;
    TRPFAddress *address;
    pferror_t pferror;

    addressString = [[TRString alloc] initWithCString: remoteAddress];
    address = [[TRPFAddress alloc] initWithPresentationAddress: addressString];
    [addressString release];
    if (connecting) {
        [TRLog debug: "Adding address \"%s\" to packet filter table \"%s\".", remoteAddress, [tableName cString]];

        if ((pferror = [ctx->pf addAddress: address toTable: tableName]) != PF_SUCCESS) {
            [TRLog error: "Failed to add address \"%s\" to table \"%s\": %s", remoteAddress, [tableName cString], [TRPacketFilterUtil stringForError: pferror]];
            [address release];
            return NO;
        }
    } else {
        [TRLog debug: "Removing address \"%s\" from packet filter table \"%s\".", remoteAddress, [tableName cString]];
        if ((pferror = [ctx->pf deleteAddress: address fromTable: tableName]) != PF_SUCCESS) {
            [TRLog error: "Failed to remove address \"%s\" from table \"%s\": %s",
                remoteAddress, [tableName cString], [TRPacketFilterUtil stringForError: pferror]];
            [address release];
            return NO;
        }
    }
    [address release];

    return YES;
}
#endif /* HAVE_PF */


/** Handle both connection and disconnection events. */
OPENVPN_PLUGIN_DEF int openvpn_plugin_func_v2 (
    openvpn_plugin_handle_t handle,
    const int type,
    const char *argv[],
    const char *envp[],
    void *per_client_context,
    struct openvpn_plugin_string_list **return_list)
{
    const char *username;
    const char *password;
    const char *remoteAddress;
    int ret = OPENVPN_PLUGIN_FUNC_ERROR;

     /* Context handle for the OpenVPN Plugin */
    ldap_ctx *ctx = handle;
    ctx->pcc = per_client_context;

    username = get_env("username", envp);
    password = get_env("password", envp);
    ctx->acf = get_env("auth_control_file", envp);
    remoteAddress = get_env("ifconfig_pool_remote_ip", envp);

    switch (type) {
        /* Password Authentication */
        case OPENVPN_PLUGIN_AUTH_USER_PASS_VERIFY:
            if (!ctx->password) {
                [TRLog debug: "No remote password supplied to OpenVPN LDAP Plugin (OPENVPN_PLUGIN_AUTH_USER_PASS_VERIFY."];
            }
            else {
                // pthread_mutex_lock(&ctx->ldap_ctx_lock);
                ctx->username = malloc(sizeof(char) * 256 + 1);
                ctx->password = malloc(sizeof(char) * 256 + 1);
                strncpy(ctx->username, username, 256);
                strncpy(ctx->password, password, 256); // really this shouldn't exceed this...
                pthread_create(&ctx->async_auth_thread, NULL, &async_handle_auth_user_pass_verify, (void *) ctx);
                ret = OPENVPN_PLUGIN_FUNC_DEFERRED;
            }
            break;
        /* New connection established */
        case OPENVPN_PLUGIN_CLIENT_CONNECT:
            if (!remoteAddress) {
                [TRLog debug: "No remote address supplied to OpenVPN LDAP Plugin (OPENVPN_PLUGIN_CLIENT_CONNECT)."];
            } else {
                //ret = handle_client_connect_disconnect(ctx, ldap, ldapUser, remoteAddress, YES);
                ret = OPENVPN_PLUGIN_FUNC_SUCCESS;
            }
            break;
        case OPENVPN_PLUGIN_CLIENT_DISCONNECT:
            if (!remoteAddress) {
                [TRLog debug: "No remote address supplied to OpenVPN LDAP Plugin (OPENVPN_PLUGIN_CLIENT_DISCONNECT)."];
            } else {
                //ret = handle_client_connect_disconnect(ctx, ldap, ldapUser, remoteAddress, NO);
                ret = OPENVPN_PLUGIN_FUNC_SUCCESS;
            }
            break;
        default:
            [TRLog debug: "Unhandled plugin type in OpenVPN LDAP Plugin (type=%d)", type];
            break;
    }

    return ret;
}
