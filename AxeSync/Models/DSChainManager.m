//
//  DSChainManager.m
//  AxeSync
//
//  Created by Sam Westrich on 5/6/18.
//

#import "DSChainManager.h"
#import "DSChainEntity+CoreDataClass.h"
#import "NSManagedObject+Sugar.h"
#import "Reachability.h"
#import "DSPriceManager.h"
#import "NSMutableData+Axe.h"
#import "NSData+Bitcoin.h"
#import "NSString+Axe.h"
#import "DSWallet.h"
#import "AxeSync.h"
#include <arpa/inet.h>

#define FEE_PER_KB_URL       0 //not supported @"https://api.breadwallet.com/fee-per-kb"
#define DEVNET_CHAINS_KEY  @"DEVNET_CHAINS_KEY"
#define SPEND_LIMIT_AMOUNT_KEY  @"SPEND_LIMIT_AMOUNT"

@interface DSChainManager()

@property (nonatomic,strong) NSMutableArray * knownChains;
@property (nonatomic,strong) NSMutableArray * knownDevnetChains;
@property (nonatomic,strong) NSMutableDictionary * devnetGenesisDictionary;
@property (nonatomic,strong) Reachability *reachability;

@end

@implementation DSChainManager

+ (instancetype)sharedInstance
{
    static id singleton = nil;
    static dispatch_once_t onceToken = 0;
    
    dispatch_once(&onceToken, ^{
        singleton = [self new];
    });
    
    return singleton;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.knownChains = [NSMutableArray array];
        NSError * error = nil;
        NSMutableDictionary * registeredDevnetIdentifiers = [getKeychainDict(DEVNET_CHAINS_KEY, &error) mutableCopy];
        self.knownDevnetChains = [NSMutableArray array];
        for (NSString * string in registeredDevnetIdentifiers) {
            NSArray<DSCheckpoint*>* checkpointArray = registeredDevnetIdentifiers[string];
            [self.knownDevnetChains addObject:[DSChain setUpDevnetWithIdentifier:string withCheckpoints:checkpointArray withDefaultPort:DEVNET_STANDARD_PORT withDefaultDapiPort:DEVNET_DAPI_STANDARD_PORT]];
        }
        
        self.reachability = [Reachability reachabilityForInternetConnection];
    }
    return self;
}

-(DSChainPeerManager*)mainnetManager {
    static id _mainnetManager = nil;
    static dispatch_once_t mainnetToken = 0;
    
    dispatch_once(&mainnetToken, ^{
        DSChain * mainnet = [DSChain mainnet];
        _mainnetManager = [[DSChainPeerManager alloc] initWithChain:mainnet];
        mainnet.peerManagerDelegate = _mainnetManager;
        
        [self.knownChains addObject:[DSChain mainnet]];
    });
    return _mainnetManager;
}

-(DSChainPeerManager*)testnetManager {
    static id _testnetManager = nil;
    static dispatch_once_t testnetToken = 0;
    
    dispatch_once(&testnetToken, ^{
        DSChain * testnet = [DSChain testnet];
        _testnetManager = [[DSChainPeerManager alloc] initWithChain:testnet];
        testnet.peerManagerDelegate = _testnetManager;
        [self.knownChains addObject:[DSChain testnet]];
    });
    return _testnetManager;
}


-(DSChainPeerManager*)devnetManagerForChain:(DSChain*)chain {
    static dispatch_once_t devnetToken = 0;
    dispatch_once(&devnetToken, ^{
        self.devnetGenesisDictionary = [NSMutableDictionary dictionary];
    });
    NSValue * genesisValue = uint256_obj(chain.genesisHash);
    DSChainPeerManager * devnetChainPeerManager = nil;
    @synchronized(self) {
        if (![self.devnetGenesisDictionary objectForKey:genesisValue]) {
            devnetChainPeerManager = [[DSChainPeerManager alloc] initWithChain:chain];
            chain.peerManagerDelegate = devnetChainPeerManager;
            [self.knownChains addObject:chain];
            [self.knownDevnetChains addObject:chain];
            [self.devnetGenesisDictionary setObject:devnetChainPeerManager forKey:genesisValue];
        } else {
            devnetChainPeerManager = [self.devnetGenesisDictionary objectForKey:genesisValue];
        }
    }
    return devnetChainPeerManager;
}

-(DSChainPeerManager*)peerManagerForChain:(DSChain*)chain {
    if ([chain isMainnet]) {
        return [self mainnetManager];
    } else if ([chain isTestnet]) {
        return [self testnetManager];
    } else if ([chain isDevnetAny]) {
        return [self devnetManagerForChain:chain];
    }
    return nil;
}

-(NSArray*)devnetChains {
    return [self.knownDevnetChains copy];
}

-(NSArray*)chains {
    return [self.knownChains copy];
}

-(void)updateDevnetChain:(DSChain*)chain forServiceLocations:(NSMutableOrderedSet<NSString*>*)serviceLocations standardPort:(uint32_t)standardPort dapiPort:(uint32_t)dapiPort protocolVersion:(uint32_t)protocolVersion minProtocolVersion:(uint32_t)minProtocolVersion sporkAddress:(NSString*)sporkAddress sporkPrivateKey:(NSString*)sporkPrivateKey {
    DSChainPeerManager * peerManager = [self peerManagerForChain:chain];
    [peerManager clearRegisteredPeers];
    if (protocolVersion) {
        chain.protocolVersion = protocolVersion;
    }
    if (minProtocolVersion) {
        chain.minProtocolVersion = minProtocolVersion;
    }
    if (sporkAddress && [sporkAddress isValidAxeDevnetAddress]) {
        chain.sporkAddress = sporkAddress;
    }
    if (sporkPrivateKey && [sporkPrivateKey isValidAxeDevnetPrivateKey]) {
        chain.sporkPrivateKey = sporkPrivateKey;
    }
    for (NSString * serviceLocation in serviceLocations) {
        NSArray * serviceArray = [serviceLocation componentsSeparatedByString:@":"];
        NSString * address = serviceArray[0];
        NSString * port = ([serviceArray count] > 1)? serviceArray[1]:nil;
        UInt128 ipAddress = { .u32 = { 0, 0, CFSwapInt32HostToBig(0xffff), 0 } };
        struct in_addr addrV4;
        struct in6_addr addrV6;
        if (inet_aton([address UTF8String], &addrV4) != 0) {
            uint32_t ip = ntohl(addrV4.s_addr);
            ipAddress.u32[3] = CFSwapInt32HostToBig(ip);
            NSLog(@"%08x", ip);
        } else if (inet_pton(AF_INET6, [address UTF8String], &addrV6)) {
            //todo support IPV6
            NSLog(@"we do not yet support IPV6");
        } else {
            NSLog(@"invalid address");
        }
        
        [peerManager registerPeerAtLocation:ipAddress port:port?[port intValue]:standardPort dapiPort:dapiPort];
    }
}

-(DSChain*)registerDevnetChainWithIdentifier:(NSString*)identifier forServiceLocations:(NSMutableOrderedSet<NSString*>*)serviceLocations standardPort:(uint32_t)standardPort dapiPort:(uint32_t)dapiPort protocolVersion:(uint32_t)protocolVersion minProtocolVersion:(uint32_t)minProtocolVersion sporkAddress:(NSString*)sporkAddress sporkPrivateKey:(NSString*)sporkPrivateKey {
    NSError * error = nil;
    
    DSChain * chain = [DSChain setUpDevnetWithIdentifier:identifier withCheckpoints:nil withDefaultPort:standardPort withDefaultDapiPort:dapiPort];
    if (protocolVersion) {
        chain.protocolVersion = protocolVersion;
    }
    if (minProtocolVersion) {
        chain.minProtocolVersion = minProtocolVersion;
    }
    if (sporkAddress && [sporkAddress isValidAxeDevnetAddress]) {
        chain.sporkAddress = sporkAddress;
    }
    if (sporkPrivateKey && [sporkPrivateKey isValidAxeDevnetPrivateKey]) {
        chain.sporkPrivateKey = sporkPrivateKey;
    }
    DSChainPeerManager * peerManager = [self peerManagerForChain:chain];
    for (NSString * serviceLocation in serviceLocations) {
        NSArray * serviceArray = [serviceLocation componentsSeparatedByString:@":"];
        NSString * address = serviceArray[0];
        NSString * port = ([serviceArray count] > 1)? serviceArray[1]:nil;
        UInt128 ipAddress = { .u32 = { 0, 0, CFSwapInt32HostToBig(0xffff), 0 } };
        struct in_addr addrV4;
        struct in6_addr addrV6;
        if (inet_aton([address UTF8String], &addrV4) != 0) {
            uint32_t ip = ntohl(addrV4.s_addr);
            ipAddress.u32[3] = CFSwapInt32HostToBig(ip);
            NSLog(@"%08x", ip);
        } else if (inet_pton(AF_INET6, [address UTF8String], &addrV6)) {
            //todo support IPV6
            NSLog(@"we do not yet support IPV6");
        } else {
            NSLog(@"invalid address");
        }
        
        [peerManager registerPeerAtLocation:ipAddress port:port?[port intValue]:standardPort dapiPort:dapiPort];
    }
    
    NSMutableDictionary * registeredDevnetsDictionary = [getKeychainDict(DEVNET_CHAINS_KEY, &error) mutableCopy];
    
    if (!registeredDevnetsDictionary) registeredDevnetsDictionary = [NSMutableDictionary dictionary];
    if (![[registeredDevnetsDictionary allKeys] containsObject:identifier]) {
        [registeredDevnetsDictionary setObject:chain.checkpoints forKey:identifier];
        setKeychainDict(registeredDevnetsDictionary, DEVNET_CHAINS_KEY, NO);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:DSChainsDidChangeNotification object:nil];
    });
    return chain;
}

-(void)removeDevnetChain:(DSChain* _Nonnull)chain {
    [[DSAuthenticationManager sharedInstance] authenticateWithPrompt:@"Remove Devnet?" andTouchId:FALSE alertIfLockout:NO completion:^(BOOL authenticatedOrSuccess, BOOL cancelled) {
        if (!cancelled && authenticatedOrSuccess) {
            NSError * error = nil;
            DSChainPeerManager * chainPeerManager = [self peerManagerForChain:chain];
            [chainPeerManager clearRegisteredPeers];
            NSMutableDictionary * registeredDevnetsDictionary = [getKeychainDict(DEVNET_CHAINS_KEY, &error) mutableCopy];
            
            if (!registeredDevnetsDictionary) registeredDevnetsDictionary = [NSMutableDictionary dictionary];
            if ([[registeredDevnetsDictionary allKeys] containsObject:chain.devnetIdentifier]) {
                [registeredDevnetsDictionary removeObjectForKey:chain.devnetIdentifier];
                setKeychainDict(registeredDevnetsDictionary, DEVNET_CHAINS_KEY, NO);
            }
            [chain wipeWalletsAndDerivatives];
            [[AxeSync sharedSyncController] wipePeerDataForChain:chain];
            [[AxeSync sharedSyncController] wipeBlockchainDataForChain:chain];
            [[AxeSync sharedSyncController] wipeSporkDataForChain:chain];
            [[AxeSync sharedSyncController] wipeMasternodeDataForChain:chain];
            [[AxeSync sharedSyncController] wipeGovernanceDataForChain:chain];
            [[AxeSync sharedSyncController] wipeWalletDataForChain:chain forceReauthentication:NO]; //this takes care of blockchain info as well;
            [self.knownDevnetChains removeObject:chain];
            [self.knownChains removeObject:chain];
            NSValue * genesisValue = uint256_obj(chain.genesisHash);
            [self.devnetGenesisDictionary removeObjectForKey:genesisValue];
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:DSChainsDidChangeNotification object:nil];
            });
        }
    }];
    
}

// MARK: - Spending Limits

// amount that can be spent using touch id without pin entry
- (uint64_t)spendingLimit
{
    // it's ok to store this in userdefaults because increasing the value only takes effect after successful pin entry
    if (! [[NSUserDefaults standardUserDefaults] objectForKey:SPEND_LIMIT_AMOUNT_KEY]) return HAKS;
    
    return [[NSUserDefaults standardUserDefaults] doubleForKey:SPEND_LIMIT_AMOUNT_KEY];
}

- (void)setSpendingLimit:(uint64_t)spendingLimit
{
    uint64_t totalSent = 0;
    for (DSChain * chain in self.chains) {
        for (DSWallet * wallet in chain.wallets) {
            totalSent += wallet.totalSent;
        }
    }
    if (setKeychainInt((spendingLimit > 0) ? totalSent + spendingLimit : 0, SPEND_LIMIT_KEY, NO)) {
        // use setDouble since setInteger won't hold a uint64_t
        [[NSUserDefaults standardUserDefaults] setDouble:spendingLimit forKey:SPEND_LIMIT_AMOUNT_KEY];
    }
}

-(void)resetSpendingLimits {
    
    uint64_t limit = self.spendingLimit;
    uint64_t totalSent = 0;
    for (DSChain * chain in self.chains) {
        for (DSWallet * wallet in chain.wallets) {
            totalSent += wallet.totalSent;
        }
    }
    if (limit > 0) setKeychainInt(totalSent + limit, SPEND_LIMIT_KEY, NO);
    
}


// MARK: - floating fees

- (void)updateFeePerKb
{
    if (self.reachability.currentReachabilityStatus == NotReachable) return;
    
#if (!!FEE_PER_KB_URL)
    
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:FEE_PER_KB_URL]
                                                       cachePolicy:NSURLRequestReloadIgnoringCacheData timeoutInterval:10.0];
    
    //    NSLog(@"%@", req.URL.absoluteString);
    
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                     completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                                         if (error != nil) {
                                             NSLog(@"unable to fetch fee-per-kb: %@", error);
                                             return;
                                         }
                                         
                                         NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
                                         
                                         if (error || ! [json isKindOfClass:[NSDictionary class]] ||
                                             ! [json[@"fee_per_kb"] isKindOfClass:[NSNumber class]]) {
                                             NSLog(@"unexpected response from %@:\n%@", req.URL.host,
                                                   [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
                                             return;
                                         }
                                         
                                         uint64_t newFee = [json[@"fee_per_kb"] unsignedLongLongValue];
                                         NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
                                         
                                         if (newFee >= MIN_FEE_PER_KB && newFee <= MAX_FEE_PER_KB && newFee != [defs doubleForKey:FEE_PER_KB_KEY]) {
                                             NSLog(@"setting new fee-per-kb %lld", newFee);
                                             [defs setDouble:newFee forKey:FEE_PER_KB_KEY]; // use setDouble since setInteger won't hold a uint64_t
                                             _wallet.feePerKb = newFee;
                                         }
                                     }] resume];
    
#else
    return;
#endif
}

@end
