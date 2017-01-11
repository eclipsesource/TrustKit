/*
 
 ssl_pin_verifier.m
 TrustKit
 
 Copyright 2015 The TrustKit Project Authors
 Licensed under the MIT license, see associated LICENSE file for terms.
 See AUTHORS file for the list of project authors.
 
 */

#import "ssl_pin_verifier.h"
#import "domain_registry.h"
#import "public_key_utils.h"
#import "TrustKit+Private.h"

#define WildcardDomainPrefix @"*."

#pragma mark Utility functions

static BOOL isSubdomain(NSString *domain, NSString *subdomain)
{
    size_t domainRegistryLength = GetRegistryLength([domain UTF8String]);
    if (GetRegistryLength([subdomain UTF8String]) != domainRegistryLength)
    {
        // Different TLDs
        return NO;
    }

    // Retrieve the main domain without the TLD
    // When initializing TrustKit, we check that [domain length] > domainRegistryLength
    NSString *domainLabel = [domain substringToIndex:([domain length] - domainRegistryLength - 1)];

    // Retrieve the subdomain's domain without the TLD
    NSString *subdomainLabel = [subdomain substringToIndex:([subdomain length] - domainRegistryLength - 1)];

    // Does the subdomain contain the domain
    NSArray *subComponents = [subdomainLabel componentsSeparatedByString:domainLabel];
    if ([[subComponents lastObject] isEqualToString:@""])
    {
        // This is a subdomain
        return YES;
    }

    return NO;
}


NSString *getPinningConfigurationKeyForDomain(NSString *hostname, NSDictionary *trustKitConfiguration)
{
    NSString *configHostname = nil;
    NSDictionary *domainsPinningPolicy = trustKitConfiguration[kTSKPinnedDomains];

    if (domainsPinningPolicy[hostname] == nil)
    {
        // No pins explicitly configured for this domain
        // Look for an includeSubdomain pin that applies
        for (NSString *pinnedServerName in domainsPinningPolicy)
        {
            // Check each domain configured with the includeSubdomain flag
            if ([domainsPinningPolicy[pinnedServerName][kTSKIncludeSubdomains] boolValue])
            {
                // Is the server a subdomain of this pinned server?
                TSKLog(@"Checking includeSubdomains configuration for %@", pinnedServerName);

                if ([pinnedServerName rangeOfString:WildcardDomainPrefix].location == 0) {
                    NSString* domainName = [pinnedServerName substringFromIndex:WildcardDomainPrefix.length];
                    if (![domainName isEqualToString:hostname] && isSubdomain(domainName, hostname))
                    {
                        // Yes; let's use the parent domain's pinning configuration
                        TSKLog(@"Applying includeSubdomains configuration from %@ to %@", pinnedServerName, hostname);
                        configHostname = pinnedServerName;
                        break;
                    }
                }
            }
        }
    }
    else
    {
        // This hostname has a pinnning configuration
        configHostname = hostname;
    }

    if (configHostname == nil)
    {
        TSKLog(@"Domain %@ is not pinned", hostname);
    }
    return configHostname;
}


#pragma mark SSL Pin Verifier

TSKPinValidationResult verifyPublicKeyPin(SecTrustRef serverTrust, NSString *serverHostname, NSArray<NSNumber *> *supportedAlgorithms, NSSet<NSData *> *knownPins)
{
    if ((serverTrust == NULL) || (supportedAlgorithms == nil) || (knownPins == nil))
    {
        TSKLog(@"Invalid pinning parameters for %@", serverHostname);
        return TSKPinValidationResultErrorInvalidParameters;
    }

    // First re-check the certificate chain using the default SSL validation in case it was disabled
    // This gives us revocation (only for EV certs I think?) and also ensures the certificate chain is sane
    // And also gives us the exact path that successfully validated the chain
    CFRetain(serverTrust);

    // Create and use a sane SSL policy to force hostname validation, even if the supplied trust has a bad
    // policy configured (such as one from SecPolicyCreateBasicX509())
    SecPolicyRef SslPolicy = SecPolicyCreateSSL(YES, (__bridge CFStringRef)(serverHostname));
    SecTrustSetPolicies(serverTrust, SslPolicy);
    CFRelease(SslPolicy);

    SecTrustResultType trustResult = 0;
    if (SecTrustEvaluate(serverTrust, &trustResult) != errSecSuccess)
    {
        TSKLog(@"SecTrustEvaluate error for %@", serverHostname);
        CFRelease(serverTrust);
        return TSKPinValidationResultErrorInvalidParameters;
    }

    if ((trustResult != kSecTrustResultUnspecified) && (trustResult != kSecTrustResultProceed))
    {
        // Default SSL validation failed
        CFDictionaryRef evaluationDetails = SecTrustCopyResult(serverTrust);
        TSKLog(@"Error: default SSL validation failed for %@: %@", serverHostname, evaluationDetails);
        CFRelease(evaluationDetails);
        CFRelease(serverTrust);
        return TSKPinValidationResultFailedCertificateChainNotTrusted;
    }

    // Check each certificate in the server's certificate chain (the trust object); start with the CA all the way down to the leaf
    CFIndex certificateChainLen = SecTrustGetCertificateCount(serverTrust);
    for(int i=(int)certificateChainLen-1;i>=0;i--)
    {
        // Extract the certificate
        SecCertificateRef certificate = SecTrustGetCertificateAtIndex(serverTrust, i);
        CFStringRef certificateSubject = SecCertificateCopySubjectSummary(certificate);
        TSKLog(@"Checking certificate with CN: %@", certificateSubject);
        CFRelease(certificateSubject);

        // For each public key algorithm flagged as supported in the config, generate the subject public key info hash
        for (NSNumber *savedAlgorithm in supportedAlgorithms)
        {
            TSKPublicKeyAlgorithm algorithm = [savedAlgorithm integerValue];
            NSData *subjectPublicKeyInfoHash = hashSubjectPublicKeyInfoFromCertificate(certificate, algorithm);
            if (subjectPublicKeyInfoHash == nil)
            {
                TSKLog(@"Error - could not generate the SPKI hash for %@", serverHostname);
                CFRelease(serverTrust);
                return TSKPinValidationResultErrorCouldNotGenerateSpkiHash;
            }

            // Is the generated hash in our set of pinned hashes ?
            TSKLog(@"Testing SSL Pin %@", subjectPublicKeyInfoHash);
            if ([knownPins containsObject:subjectPublicKeyInfoHash])
            {
                TSKLog(@"SSL Pin found for %@", serverHostname);
                CFRelease(serverTrust);
                return TSKPinValidationResultSuccess;
            }
        }
    }

    // If we get here, we didn't find any matching SPKI hash in the chain
    TSKLog(@"Error: SSL Pin not found for %@", serverHostname);
    CFRelease(serverTrust);
    return TSKPinValidationResultFailed;
}
