//
//  DSCreateBlockchainUserViewController.h
//  AxeSync_Example
//
//  Created by Sam Westrich on 7/27/18.
//  Copyright © 2018 Axe Core Group. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "DSWalletChooserViewController.h"
#import "DSAccountChooserViewController.h"

@interface DSCreateBlockchainUserViewController : UITableViewController <DSWalletChooserDelegate,DSAccountChooserDelegate>

@property (nonatomic,strong) DSChainPeerManager * chainPeerManager;

@end
