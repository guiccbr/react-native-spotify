//
//  RNSpotifyAuth.m
//  RNSpotify
//
//  Created by Luis Finke on 3/3/19.
//  Copyright © 2019 Facebook. All rights reserved.
//

#import "RNSpotifyAuth.h"
#import "RNSpotifyUtils.h"
#import "HelperMacros.h"

@interface RNSpotifyAuth() {
	BOOL _renewingSession;
	BOOL _retryRenewalUntilResponse;
	NSMutableArray<RNSpotifyCompletion*>* _renewCallbacks;
	NSMutableArray<RNSpotifyCompletion*>* _renewUntilResponseCallbacks;
}
@end

@implementation RNSpotifyAuth

-(id)init {
	if(self = [super init]) {
		_session = nil;

		_renewingSession = NO;
		_retryRenewalUntilResponse = NO;
		_renewCallbacks = [NSMutableArray array];
		_renewUntilResponseCallbacks = [NSMutableArray array];
	}
	return self;
}

-(void)loadWithOptions:(RNSpotifyLoginOptions*)options {
	if(_sessionUserDefaultsKey == nil) {
		return;
	}
	NSUserDefaults* prefs = NSUserDefaults.standardUserDefaults;
	_session = [RNSpotifySessionData sessionFromUserDefaults:prefs key:_sessionUserDefaultsKey];
	if(_session != nil) {
		_clientID = options.clientID;
		_tokenRefreshURL = options.tokenRefreshURL;
		_tokenRefreshURLAuthorization = options.tokenRefreshURLAuthorization;
		_redirectURL = options.redirectURL;
	}
}

-(void)save {
	if (_sessionUserDefaultsKey == nil) {
		return;
	}
	NSUserDefaults* prefs = NSUserDefaults.standardUserDefaults;
	if(_session != nil) {
		[_session saveToUserDefaults:prefs key:_sessionUserDefaultsKey];
	}
	else {
		[prefs removeObjectForKey:_sessionUserDefaultsKey];
	}
}

-(void)startSession:(RNSpotifySessionData*)session options:(RNSpotifyLoginOptions*)options {
	_session = session;
	_clientID = options.clientID;
	_tokenRefreshURL = options.tokenRefreshURL;
	_tokenRefreshURLAuthorization = options.tokenRefreshURLAuthorization;
	[self save];
}

-(void)clearSession {
	_session = nil;
	_clientID = nil;
	_tokenRefreshURL = nil;
	_tokenRefreshURLAuthorization = nil;
	[self save];
}

-(BOOL)isLoggedIn {
	if(_session != nil && _session.accessToken != nil) {
		return YES;
	}
	return NO;
}

-(BOOL)isSessionValid {
	if(_session != nil && _session.isValid) {
		return YES;
	}
	return NO;
}

-(BOOL)hasStreamingScope {
	if(_session == nil) {
		return NO;
	}
	return [_session hasScope:@"streaming"];
}

-(BOOL)canRefreshSession {
	if(_session != nil && _session.refreshToken != nil && _tokenRefreshURL != nil) {
		return YES;
	}
	return NO;
}



#pragma mark - Cookies

-(void)clearCookies:(void(^)())completion {
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		NSHTTPCookieStorage *storage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
		for (NSHTTPCookie *cookie in [storage cookies]) {
			[storage deleteCookie:cookie];
		}
		[[NSUserDefaults standardUserDefaults] synchronize];
		dispatch_async(dispatch_get_main_queue(), ^{
			if(completion != nil) {
				completion();
			}
		});
	});
}




#pragma mark - Session Renewal

-(void)renewSessionIfNeeded:(RNSpotifyCompletion*)completion waitForDefinitiveResponse:(BOOL)waitForDefinitiveResponse {
	if(_session == nil || _session.accessToken == nil || [self isSessionValid]) {
		// not logged in or session does not need renewal
		[completion resolve:@NO];
	}
	else if(_session.refreshToken == nil) {
		// no refresh token to renew session with, so the session has expired
		[completion reject:[RNSpotifyError errorWithCodeObj:RNSpotifyErrorCode.SessionExpired]];
	}
	else {
		[self renewSession:[RNSpotifyCompletion onReject:^(RNSpotifyError* error) {
			[completion reject:error];
		} onResolve:^(id result) {
			[completion resolve:result];
		}] waitForDefinitiveResponse:waitForDefinitiveResponse];
	}
}

-(void)renewSession:(RNSpotifyCompletion*)completion waitForDefinitiveResponse:(BOOL)waitForDefinitiveResponse {
	if(![self canRefreshSession]) {
		[completion resolve:@NO];
		return;
	}

	// add completion to be called when the renewal finishes
	if(completion != nil) {
		if(waitForDefinitiveResponse) {
			@synchronized (_renewUntilResponseCallbacks) {
				[_renewUntilResponseCallbacks addObject:completion];
			}
		}
		else {
			@synchronized (_renewCallbacks) {
				[_renewCallbacks addObject:completion];
			}
		}
	}

	dispatch_async(dispatch_get_main_queue(), ^{
		// determine whether to retry renewal if a definitive response isn't given
		if(waitForDefinitiveResponse) {
			_retryRenewalUntilResponse = YES;
		}

		// if we're already in the process of renewing the session, don't continue
		if(_renewingSession) {
			return;
		}
		_renewingSession = true;

		// create request body
		NSDictionary* params = @{
			@"refresh_token": _session.refreshToken,
			@"redirect_uri": _redirectURL
		};

		// perform token refresh
		[self.class performTokenURLRequestTo:_tokenRefreshURL authorization:_tokenRefreshURLAuthorization params:params completion:[RNSpotifyCompletion onComplete:^(NSDictionary* result, RNSpotifyError* requestError) {
			dispatch_async(dispatch_get_main_queue(), ^{
				RNSpotifyError* error = requestError;
				_renewingSession = NO;

				// determine if session was renewed
				BOOL _renewed = NO;
				if(error == nil && _session != nil && _session.refreshToken != nil) {
					NSDictionary* data = result[@"data"];
					NSString* newAccessToken = data[@"access_token"];
					NSNumber* expireSeconds = data[@"expires_in"];
					if(_session.accessToken != nil) {
						if(newAccessToken != nil && [newAccessToken isKindOfClass:[NSString class]] && expireSeconds != nil && [expireSeconds isKindOfClass:[NSNumber class]]) {
							_session.accessToken = newAccessToken;
							_session.expireDate = [RNSpotifySessionData expireDateFromSeconds:expireSeconds.integerValue];
							[self save];
							_renewed = YES;
						}
						else {
							// was not renewed
							error = [RNSpotifyError errorWithCodeObj:RNSpotifyErrorCode.BadResponse message:@"Missing expected response parameters"];
						}
					}
				}

				// call renewal callbacks
				NSArray<RNSpotifyCompletion<NSNumber*>*>* tmpRenewCallbacks;
				@synchronized(_renewCallbacks) {
					tmpRenewCallbacks = [NSArray arrayWithArray:_renewCallbacks];
					[_renewCallbacks removeAllObjects];
				}
				for(RNSpotifyCompletion<NSNumber*>* completion in tmpRenewCallbacks) {
					if(error != nil) {
						[completion reject:error];
					}
					else {
						[completion resolve:@(_renewed)];
					}
				}

				// ensure an actual session renewal error (a reason to be logged out)
				if(error != nil
				   // make sure error code is not a timeout or lack of connection
				   && ([error.code isEqualToString:[RNSpotifyError httpErrorForStatusCode:0].code]
					   || [error.code isEqualToString:[RNSpotifyError httpErrorForStatusCode:408].code]
					   || [error.code isEqualToString:[RNSpotifyError httpErrorForStatusCode:504].code]
					   || [error.code isEqualToString:[RNSpotifyError httpErrorForStatusCode:598].code]
					   || [error.code isEqualToString:[RNSpotifyError httpErrorForStatusCode:599].code])) {
					error = nil;
				}

				// check if the session was renewed, or if it got a failure error
				if(_renewed || error != nil) {
					// renewal has reached a success or an error
					_retryRenewalUntilResponse = NO;

					// call renewal callbacks
					NSArray<RNSpotifyCompletion<NSNumber*>*>* tmpRenewUntilResponseCallbacks;
					@synchronized(_renewUntilResponseCallbacks) {
						tmpRenewUntilResponseCallbacks = [NSArray arrayWithArray:_renewUntilResponseCallbacks];
						[_renewUntilResponseCallbacks removeAllObjects];
					}
					for(RNSpotifyCompletion<NSNumber*>* completion in tmpRenewUntilResponseCallbacks) {
						if(error != nil) {
							[completion reject:error];
						}
						else {
							[completion resolve:@(_renewed)];
						}
					}
				}
				else if(_retryRenewalUntilResponse) {
					// retry session renewal in 2000ms
					dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2000 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
						[self renewSession:nil waitForDefinitiveResponse:YES];
					});
				}
			});
		}]];
	});
}



#pragma mark - Token API

+(void)performTokenURLRequestTo:(NSURL*)url authorization:(NSString*)authorization params:(NSDictionary*)params completion:(RNSpotifyCompletion<NSDictionary*>*)completion {
  NSString* body = [RNSpotifyUtils makeJSONBody:params];
	NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];
	request.HTTPMethod = @"POST";
	request.HTTPBody = body;

	if(authorization != nil) {
    [request setValue:authorization forHTTPHeaderField:@"Authorization"];
	}

  [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

	NSURLSessionDataTask* dataTask = [NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
		if(error != nil) {
			[completion reject:[RNSpotifyError httpErrorForStatusCode:0 message:error.localizedDescription]];
			return;
		}

		NSDictionary* responseObj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
		if(error != nil) {
			[completion reject:[RNSpotifyError errorWithCodeObj:RNSpotifyErrorCode.BadResponse message:error.localizedDescription]];
			return;
		}
		NSString* errorCode = responseObj[@"error"];
		if(errorCode != nil && ![errorCode isKindOfClass:[NSNull class]]) {
			[completion reject:[RNSpotifyError errorWithCode:errorCode message:responseObj[@"error_description"]]];
			return;
		}
		NSArray* errors = responseObj[@"errors"];
		if(errors != nil && ![errors isKindOfClass:[NSNull class]]) {
		  NSData *errorsJSON = [NSJSONSerialization dataWithJSONObject:errors options:0 error:&error];
			if (error != nil) {
				[completion reject:[RNSpotifyError errorWithCodeObj:RNSpotifyErrorCode.BadResponse message:error.localizedDescription]];
				return;
			}
      NSString* errorsJSONString = [[NSString alloc] initWithData:errorsJSON encoding:NSUTF8StringEncoding];
			[completion reject:[RNSpotifyError errorWithCodeObj:RNSpotifyErrorCode.Generic message:errorsJSONString]];
			return;
		}
		[completion resolve:responseObj];
	}];
	[dataTask resume];
}

+(void)swapCodeForToken:(NSString*)code url:(NSURL*)url authorization:(NSString*)authorization redirectURL:(NSURL*)redirectURL completion:(RNSpotifyCompletion<RNSpotifySessionData*>*)completion {
	NSDictionary* params = @{
		@"code": code,
		@"redirect_uri": redirectURL,
	};
	[self.class performTokenURLRequestTo:url authorization:authorization params:params completion:[RNSpotifyCompletion onReject:^(RNSpotifyError* error) {
		[completion reject:error];
	} onResolve:^(NSDictionary* result) {
		NSDictionary* data = result[@"data"];
		NSString* accessToken = data[@"access_token"];
		NSString* refreshToken = data[@"refresh_token"];
		NSNumber* expireSeconds = data[@"expires_in"];
		NSString* scope = data[@"scope"];
		if(accessToken == nil || ![accessToken isKindOfClass:[NSString class]] || expireSeconds == nil || ![expireSeconds isKindOfClass:[NSNumber class]]) {
			[completion reject:[RNSpotifyError errorWithCodeObj:RNSpotifyErrorCode.BadResponse message:@"Missing expected response parameters"]];
			return;
		}
		NSArray* scopes = nil;
		if(scope != nil) {
			scopes = [scope componentsSeparatedByString:@" "];
		}
		RNSpotifySessionData* session = [[RNSpotifySessionData alloc] init];
		session.accessToken = accessToken;
		session.refreshToken = refreshToken;
		session.expireDate = [RNSpotifySessionData expireDateFromSeconds:expireSeconds.integerValue];
		session.scopes = scopes;
		[completion resolve:session];
	}]];
}
@end
