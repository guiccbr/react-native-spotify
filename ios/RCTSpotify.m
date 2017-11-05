
#import "RCTSpotify.h"
#import <SpotifyAuthentication/SpotifyAuthentication.h>
#import <SpotifyMetadata/SpotifyMetadata.h>
#import <SpotifyAudioPlayback/SpotifyAudioPlayback.h>
#import "SpotifyWebViewController.h"


NSString* const RCTSpotifyErrorDomain = @"RCTSpotifyErrorDomain";


@interface RCTSpotify() <SPTAudioStreamingDelegate, SPTAudioStreamingPlaybackDelegate, SpotifyWebViewDelegate>
{
	SPTAuth* _auth;
	SPTAudioStreamingController* _player;
	
	NSNumber* _cacheSize;
	
	void(^_authControllerResponse)(BOOL loggedIn, NSError* error);
	void(^_startResponse)(BOOL loggedIn, NSError* error);
}
+(id)objFromError:(NSError*)error;

-(void)logBackInIfNeeded:(void(^)(BOOL loggedIn, NSError* error))completion;
-(void)start:(void(^)(BOOL,NSError*))completion;
@end

@implementation RCTSpotify

+(id)objFromError:(NSError*)error
{
	if(error==nil)
	{
		return [NSNull null];
	}
	return @{
		@"domain":error.domain,
		@"code":@(error.code),
		@"description":error.localizedDescription
	};
}

+(NSError*)errorWithCode:(RCTSpotifyErrorCode)code description:(NSString*)description
{
	return [NSError errorWithDomain:RCTSpotifyErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey:description}];
}

#pragma mark - React Native functions

RCT_EXPORT_MODULE()

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(test)
{
	NSLog(@"ayy lmao");
	return nil;
}

RCT_EXPORT_METHOD(initialize:(NSDictionary*)options completion:(RCTResponseSenderBlock)completion)
{
	//set default values
	_auth = [SPTAuth defaultInstance];
	_player = [SPTAudioStreamingController sharedInstance];
	_cacheSize = @(1024 * 1024 * 64);
	_authControllerResponse = nil;
	
	//if a session exists, make sure it's using the same clientID. Otherwise, kill the session
	if(_auth.session != nil)
	{
		if(![_auth.clientID isEqualToString:options[@"clientID"]])
		{
			_auth.session = nil;
		}
	}
	
	//set default options
	_auth.requestedScopes = @[SPTAuthStreamingScope];
	
	//get options
	_auth.clientID = options[@"clientID"];
	NSString* redirectURL = options[@"redirectURL"];
	if(redirectURL != nil)
	{
		_auth.redirectURL = [NSURL URLWithString:redirectURL];
	}
	NSString* sessionUserDefaultsKey = options[@"sessionUserDefaultsKey"];
	if(sessionUserDefaultsKey != nil)
	{
		_auth.sessionUserDefaultsKey = sessionUserDefaultsKey;
	}
	NSNumber* cacheSize = options[@"cacheSize"];
	if(cacheSize!=nil)
	{
		_cacheSize = cacheSize;
	}
	
	if(_player.initialized)
	{
		NSLog(@"stopping player");
		NSError* error = nil;
		if(![_player stopWithError:&error])
		{
			NSLog(@"error stopping Spotify player: %@", error.localizedDescription);
		}
	}
	
	[self logBackInIfNeeded:^(BOOL loggedIn, NSError* error) {
		if(loggedIn)
		{
			completion(@[ @YES, [NSNull null] ]);
		}
		else
		{
			completion(@[ @NO, [RCTSpotify objFromError:error] ]);
		}
	}];
}

-(void)logBackInIfNeeded:(void(^)(BOOL, NSError*))completion
{
	if(_auth.session == nil)
	{
		completion(NO, nil);
	}
	else if([_auth.session isValid])
	{
		completion(YES, nil);
	}
	else if(!_auth.hasTokenRefreshService)
	{
		completion(NO, nil);
	}
	else
	{
		[_auth renewSession:_auth.session callback:^(NSError* error, SPTSession* session){
			if(error!=nil)
			{
				completion(NO, error);
			}
			else
			{
				_auth.session = session;
				[self start:^(BOOL loggedIn, NSError* error) {
					completion(loggedIn, error);
				}];
			}
		}];
	}
}

RCT_EXPORT_METHOD(login:(RCTResponseSenderBlock)completion)
{
	//do UI logic on main thread
	dispatch_async(dispatch_get_main_queue(), ^{
		SpotifyWebViewController* authController = [[SpotifyWebViewController alloc] initWithURL:_auth.spotifyWebAuthenticationURL];
		authController.title = @"Log into Spotify";
		authController.delegate = self;
		UIViewController* rootController = [UIApplication sharedApplication].keyWindow.rootViewController;
		if(rootController == nil)
		{
			//no root view controller to present on
			completion(@[ @NO, @{@"description":@"can't login when not in foreground"} ]);
		}
		else
		{
			__weak RCTSpotify* _self = self;
			
			if(_authControllerResponse != nil)
			{
				completion(@[ @NO, [RCTSpotify objFromError:[RCTSpotify errorWithCode:RCTSpotifyErrorCodeConflictingCallbacks description:@"Cannot call login while login is already being called"]] ]);
				return;
			}
			
			//wait for handleAuthURL:
			// or spotifyWebControllerDidCancelLogin
			_authControllerResponse = ^(BOOL loggedIn, NSError* error){
				authController.view.userInteractionEnabled = NO;
				if(!loggedIn)
				{
					if(authController.presentingViewController != nil)
					{
						[authController.presentingViewController dismissViewControllerAnimated:YES completion:nil];
					}
					completion(@[ @NO, [RCTSpotify objFromError:error] ]);
					return;
				}
				[_self start:^(BOOL loggedIn, NSError* error) {
					dispatch_async(dispatch_get_main_queue(), ^{
						if(authController.presentingViewController != nil)
						{
							[authController.presentingViewController dismissViewControllerAnimated:YES completion:nil];
						}
						completion(@[ [NSNumber numberWithBool:loggedIn], [RCTSpotify objFromError:error] ]);
					});
				}];
			};
			[rootController presentViewController:authController animated:YES completion:nil];
		}
	});
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(isLoggedIn)
{
	if(_auth.session == nil)
	{
		return @NO;
	}
	else if(![_auth.session isValid])
	{
		return @NO;
	}
	return @YES;
}

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(handleAuthURL:(NSString*)urlString)
{
	NSURL* url = [NSURL URLWithString:urlString];
	if([_auth canHandleURL:url])
	{
		[_auth handleAuthCallbackWithTriggeredAuthURL:url callback:^(NSError* error, SPTSession* session){
			if(_authControllerResponse != nil)
			{
				void(^response)(BOOL, NSError*) = _authControllerResponse;
				_authControllerResponse = nil;
				if(error!=nil)
				{
					response(NO, error);
				}
				else
				{
					response(YES, nil);
				}
			}
		}];
		return @YES;
	}
	return @NO;
}

-(void)start:(void(^)(BOOL,NSError*))completion
{
	BOOL allowCaching = (_cacheSize.unsignedIntegerValue > 0);
	NSError* error = nil;
	if([_player startWithClientId:_auth.clientID audioController:nil allowCaching:allowCaching error:&error])
	{
		_player.delegate = self;
		_player.playbackDelegate = self;
		if(allowCaching)
		{
			_player.diskCache = [[SPTDiskCache alloc] initWithCapacity:_cacheSize.unsignedIntegerValue];
		}
		
		dispatch_async(dispatch_get_main_queue(), ^{
			if(_startResponse != nil)
			{
				completion(NO, [RCTSpotify errorWithCode:RCTSpotifyErrorCodeConflictingCallbacks description:@"cannot call start method while start is already being called"]);
				return;
			}
			
			//wait for audioStreamingDidLogin:
			// or audioStreaming:didRecieveError:
			_startResponse = ^(BOOL loggedIn, NSError* error){
				completion(loggedIn, error);
			};
			[_player loginWithAccessToken:_auth.session.accessToken];
		});
	}
	else
	{
		completion(NO, error);
	}
}



#pragma mark - SpotifyWebViewDelegate

-(void)spotifyWebControllerDidCancel:(SpotifyWebViewController*)webController
{
	if(_authControllerResponse != nil)
	{
		void(^response)(BOOL, NSError*) = _authControllerResponse;
		_authControllerResponse = nil;
		response(NO, nil);
	}
}



#pragma mark - SPTAudioStreamingDelegate

-(void)audioStreamingDidLogin:(SPTAudioStreamingController*)audioStreaming
{
	if(_startResponse != nil)
	{
		//do login callback
		void(^response)(BOOL,NSError*) = _startResponse;
		_startResponse = nil;
		response(YES, nil);
	}
}

-(void)audioStreaming:(SPTAudioStreamingController*)audioStreaming didReceiveError:(NSError*)error
{
	if(_startResponse != nil)
	{
		if(error.code==SPErrorGeneralLoginError || error.code==SPErrorLoginBadCredentials)
		{
			//do login callback
			void(^response)(BOOL,NSError*) = _startResponse;
			_startResponse = nil;
			response(NO, error);
		}
	}
}

@end
