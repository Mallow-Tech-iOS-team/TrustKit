//
//  TrustKit.m
//  TrustKit
//
//  Created by Alban Diquet on 2/9/15.
//  Copyright (c) 2015 Data Theorem. All rights reserved.
//

#import "TrustKit.h"
#import "TrustKit+Private.h"
#include <dlfcn.h>
#import <CommonCrypto/CommonDigest.h>
#import "fishhook/fishhook.h"
#import "subjectPublicKeyHash.h"


// Info.plist key we read the public key hashes from
static const NSString *kTSKConfiguration = @"TSKConfiguration";

// Keys for each domain within our dictionnary
static const NSString *kTSKPublicKeyHashes = @"TSKPublicKeyHashes";
static const NSString *kTSKIncludeSubdomains = @"TSKIncludeSubdomains";
static const NSString *kTSKPublicKeyTypes = @"TSKPublicKeyTypes";
static const NSString *kTSKReportUris = @"TSKReportUris";


#pragma mark TrustKit Global State
// Global dictionnary for storing the public key hashes and domains
static NSDictionary *_subjectPublicKeyInfoPins = nil;

// Global preventing multiple initializations (double function interposition, etc.)
static BOOL _isTrustKitInitialized = NO;



#pragma mark SSL Pin Validator


BOOL verifyPublicKeyPin(SecTrustRef serverTrust, NSString *serverName, NSDictionary *TrustKitConfiguration)
{
    if ((serverTrust == NULL) || (serverName == NULL))
    {
        return NO;
    }
    
    // First re-check the certificate chain using the default SSL validation in case it was disabled
    // This gives us revocation (only for EV certs I think?) and also ensures the certificate chain is sane
    // And also gives us the exact path that successfully validated the chain
    SecTrustResultType trustResult;
    SecTrustEvaluate(serverTrust, &trustResult);
    if ((trustResult != kSecTrustResultUnspecified) && (trustResult != kSecTrustResultProceed))
    {
        // Default SSL validation failed
        NSLog(@"Error: default SSL validation failed");
        return NO;
    }
    
    // Let's find at least one of the pins in the certificate chain
    NSSet *serverPins = TrustKitConfiguration[serverName][kTSKPublicKeyHashes];
    

    // Check each certificate in the server's certificate chain (the trust object)
    CFIndex certificateChainLen = SecTrustGetCertificateCount(serverTrust);
    for(int i=0;i<certificateChainLen;i++)
    {
        // Extract and hash the certificate
        SecCertificateRef certificate = SecTrustGetCertificateAtIndex(serverTrust, i);
        
        NSData *subjectPublicKeyInfoHash = hashSubjectPublicKeyInfoFromCertificate(certificate);
        // TODO: error checking
        
        // Is the generated hash in our set of pinned hashes ?
        NSLog(@"Testing SSL Pin %@", subjectPublicKeyInfoHash);
        if ([serverPins containsObject:subjectPublicKeyInfoHash])
        {
            NSLog(@"SSL Pin found");
            return YES;
        }
    }
    
    // If we get here, we didn't find any matching certificate in the chain
    NSLog(@"Error: SSL Pin not found");
    return NO;
}



#pragma mark SSLHandshake Hook

static OSStatus (*original_SSLHandshake)(SSLContextRef context);

static OSStatus replaced_SSLHandshake(SSLContextRef context)
{
    OSStatus result = original_SSLHandshake(context);
    if (result == noErr)
    {
        // The handshake was sucessful, let's do our additional checks on the server certificate
        char *serverName = NULL;
        size_t serverNameLen = 0;
        // TODO: error handling
        
        // Get the server's domain name
        SSLGetPeerDomainNameLength (context, &serverNameLen);
        serverName = malloc(serverNameLen+1);
        SSLGetPeerDomainName(context, serverName, &serverNameLen);
        serverName[serverNameLen] = '\0';
        NSLog(@"Result %d - %s", result, serverName);
        
        NSString *serverNameStr = [NSString stringWithUTF8String:serverName];
        free(serverName);
        
        
        if (_subjectPublicKeyInfoPins == NULL)
        {   // TODO: return an error
            NSLog(@"Error: pin not initialized?");
            return NO;
        }
        
        
        // Is this domain name pinned ?
        BOOL wasPinValidationSuccessful = NO;
        if (_subjectPublicKeyInfoPins[serverNameStr])
        {
            // Let's check the certificate chain with our SSL pins
            NSLog(@"Server IS pinned");
            SecTrustRef serverTrust;
            SSLCopyPeerTrust(context, &serverTrust);
            wasPinValidationSuccessful = verifyPublicKeyPin(serverTrust, serverNameStr, _subjectPublicKeyInfoPins);
        }
        else
        {
            // No SSL pinning and regular SSL validation was already done by SSLHandshake and was sucessful
            NSLog(@"Server not pinned");
            wasPinValidationSuccessful = YES;
        }
        
        if (wasPinValidationSuccessful == NO)
        {
            // The certificate chain did not contain the expected pins; force an error
            result = errSSLXCertChainInvalid;
        }
    }
    
    return result;
}


#pragma mark Framework Initialization 


NSDictionary *parseTrustKitArguments(NSDictionary *TrustKitArguments)
{
    // Convert settings supplied by the user to a configuration dictionnary that can be used by TrustKit
    // This includes checking the sanity of the settings and converting public key hashes/pins from an
    // NSSArray of NSStrings (as provided by the user) to an NSSet of NSData (as needed by TrustKit)
    
    NSMutableDictionary *finalConfiguration = [[NSMutableDictionary alloc]init];
    
    for (NSString *domainName in TrustKitArguments)
    {
        // Retrieve the configuration for this domain
        NSDictionary *serverPinConfiguration = TrustKitArguments[domainName];
        NSMutableDictionary *serverPinFinalConfiguration = [[NSMutableDictionary alloc]init];
        
        // Extract the includeSubdomains setting
        NSNumber *shouldIncludeSubdomains = serverPinConfiguration[kTSKIncludeSubdomains];
        if (shouldIncludeSubdomains == nil)
        {
            [NSException raise:@"TrustKit configuration invalid" format:@"TrustKit was initialized with an invalid value for %@", kTSKIncludeSubdomains];
        }
        serverPinFinalConfiguration[kTSKIncludeSubdomains] = shouldIncludeSubdomains;
        
        
        // Extract the list of public key types
        NSArray *publicKeyTypes = serverPinConfiguration[kTSKPublicKeyTypes];
        if (publicKeyTypes == nil)
        {
            [NSException raise:@"TrustKit configuration invalid" format:@"TrustKit was initialized with an invalid value for %@", kTSKPublicKeyTypes];
        }
        serverPinFinalConfiguration[kTSKPublicKeyTypes] = publicKeyTypes;
        
        
        // Extract and convert the report URIs if defined
        NSArray *reportUriList = serverPinConfiguration[kTSKReportUris];
        if (reportUriList != nil)
        {
            NSMutableArray *reportUriListFinal = [NSMutableArray array];
            for (NSString *reportUriStr in reportUriList)
            {
                NSURL *reportUri = [NSURL URLWithString:reportUriStr];
                if (reportUri == nil)
                {
                    [NSException raise:@"TrustKit configuration invalid" format:@"TrustKit was initialized with an invalid value for %@", kTSKReportUris];
                }
                [reportUriListFinal addObject:reportUri];
            }

            serverPinFinalConfiguration[kTSKReportUris] = [NSArray arrayWithArray:reportUriListFinal];
        }
        
        
        // Extract and convert the public key hashes
        NSArray *serverSslPinsString = serverPinConfiguration[kTSKPublicKeyHashes];
        NSMutableArray *serverSslPinsData = [[NSMutableArray alloc] init];
        
        NSLog(@"Loading SSL pins for %@", domainName);
        for (NSString *pinnedCertificateHash in serverSslPinsString) {
            NSMutableData *pinnedCertificateHashData = [NSMutableData dataWithCapacity:CC_SHA256_DIGEST_LENGTH];
            
            // Convert the hex string to data
            if ([pinnedCertificateHash length] != CC_SHA256_DIGEST_LENGTH * 2) {
                // The public key hash doesn't have a valid size; store a null hash to make all connections fail
                NSLog(@"Bad hash for %@", domainName);
                [pinnedCertificateHashData resetBytesInRange:NSMakeRange(0, CC_SHA256_DIGEST_LENGTH)];
            }
            else {
                // Convert the hash from NSString to NSData
                char output[CC_SHA256_DIGEST_LENGTH];
                const char *input = [pinnedCertificateHash UTF8String];
                
                for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
                    sscanf(input + i * 2, "%2hhx", output + i);
                }
                [pinnedCertificateHashData replaceBytesInRange:NSMakeRange(0, CC_SHA256_DIGEST_LENGTH) withBytes:output];
            }
            
            [serverSslPinsData addObject:pinnedCertificateHashData];
        }
        
        // Save the public key hashes for this server as an NSSet for quick lookup
        serverPinFinalConfiguration[kTSKPublicKeyHashes] = [NSSet setWithArray:serverSslPinsData];
        
        // Store the whole configuration
        finalConfiguration[domainName] = [NSDictionary dictionaryWithDictionary:serverPinFinalConfiguration];
    }
    
    return finalConfiguration;
}


static void initializeTrustKit(NSDictionary *publicKeyPins)
{
    if (_isTrustKitInitialized == YES)
    {
        // TrustKit should only be initialized once so we don't double interpose SecureTransport or get into anything unexpected
        [NSException raise:@"TrustKit already initialized" format:@"TrustKit was already initialized with the following SSL pins: %@", _subjectPublicKeyInfoPins];
    }
    
    if ([publicKeyPins count] > 0)
    {
        initializeKeychain();
        
        // Convert and store the SSL pins in our global variable
        _subjectPublicKeyInfoPins = [[NSDictionary alloc]initWithDictionary:parseTrustKitArguments(publicKeyPins)];
        
        // Hook SSLHandshake()
        char functionToHook[] = "SSLHandshake";
        original_SSLHandshake = dlsym(RTLD_DEFAULT, functionToHook);
        rebind_symbols((struct rebinding[1]){{(char *)functionToHook, (void *)replaced_SSLHandshake}}, 1);

        _isTrustKitInitialized = YES;
        NSLog(@"TrustKit initialized with pins %@", _subjectPublicKeyInfoPins);
    }
}


#pragma mark Framework Initialization When Statically Linked

@implementation TrustKit


+ (void) initializeWithSslPins:(NSDictionary *)publicKeyPins
{
    NSLog(@"TrustKit started statically in App %@", CFBundleGetValueForInfoDictionaryKey(CFBundleGetMainBundle(), (__bridge CFStringRef)@"CFBundleIdentifier"));
    initializeTrustKit(publicKeyPins);
}


+ (void) resetSslPins
{
    // This is only used for tests
    resetKeychain();
    _subjectPublicKeyInfoPins = nil;
    _isTrustKitInitialized = NO;
}

@end


#pragma mark Framework Initialization When Dynamically Linked

__attribute__((constructor)) static void initialize(int argc, const char **argv)
{
    // TrustKit just got injected in the App
    CFBundleRef appBundle = CFBundleGetMainBundle();
    NSLog(@"TrustKit started dynamically in App %@", CFBundleGetValueForInfoDictionaryKey(appBundle, (__bridge CFStringRef)@"CFBundleIdentifier"));
    
    // Retrieve the SSL pins from the App's Info.plist file
    NSDictionary *publicKeyPinsFromInfoPlist = CFBundleGetValueForInfoDictionaryKey(appBundle, (__bridge CFStringRef)kTSKConfiguration);

    initializeTrustKit(publicKeyPinsFromInfoPlist);
}



