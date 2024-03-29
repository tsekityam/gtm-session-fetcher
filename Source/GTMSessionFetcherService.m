/* Copyright 2014 Google Inc. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#if !defined(__has_feature) || !__has_feature(objc_arc)
#error "This file requires ARC support."
#endif

#import "GTMSessionFetcherService.h"

NSString *const kGTMSessionFetcherServiceSessionBecameInvalidNotification
    = @"kGTMSessionFetcherServiceSessionBecameInvalidNotification";
NSString *const kGTMSessionFetcherServiceSessionKey
    = @"kGTMSessionFetcherServiceSessionKey";

@interface GTMSessionFetcher (ServiceMethods)

- (BOOL)beginFetchMayDelay:(BOOL)mayDelay
              mayAuthorize:(BOOL)mayAuthorize;

@end

@interface GTMSessionFetcherService ()

@property(atomic, strong, readwrite) NSDictionary *delayedFetchersByHost;
@property(atomic, strong, readwrite) NSDictionary *runningFetchersByHost;

@end

// Since NSURLSession doesn't support a separate delegate per task (!), instances of this
// class serve as a session delegate trampoline.
//
// This class maps a session's tasks to fetchers, and resends delegate messages to the task's
// fetcher.
@interface GTMSessionFetcherSessionDelegateDispatcher : NSObject<NSURLSessionDelegate>

// The session for the tasks in this dispatcher's task-to-fetcher map.
@property(atomic) NSURLSession *session;

// The timer interval for invalidating a session that has no active tasks.
@property(atomic) NSTimeInterval discardInterval;


- (instancetype)initWithParentService:(GTMSessionFetcherService *)parentService
               sessionDiscardInterval:(NSTimeInterval)discardInterval;

- (void)setFetcher:(GTMSessionFetcher *)fetcher
           forTask:(NSURLSessionTask *)task;
- (void)removeFetcher:(GTMSessionFetcher *)fetcher;

// When abandoning a delegate dispatcher, we want to avoid the session retaining
// the delegate after tasks complete.
- (void)abandon;

@end


@implementation GTMSessionFetcherService {
  NSMutableDictionary *_delayedFetchersByHost;
  NSMutableDictionary *_runningFetchersByHost;
  NSUInteger _maxRunningFetchersPerHost;

  // When this ivar is nil, the service will not reuse sessions.
  GTMSessionFetcherSessionDelegateDispatcher *_delegateDispatcher;

  dispatch_queue_t _callbackQueue;
  NSHTTPCookieStorage *_cookieStorage;
  NSString *_userAgent;
  NSTimeInterval _timeout;

  NSURLCredential *_credential;       // Username & password.
  NSURLCredential *_proxyCredential;  // Credential supplied to proxy servers.

  NSInteger _cookieStorageMethod;

  id<GTMFetcherAuthorizationProtocol> _authorizer;

  // For waitForCompletionOfAllFetchersWithTimeout: we need to wait on stopped fetchers since
  // they've not yet finished invoking their queued callbacks. This array is nil except when
  // waiting on fetchers.
  NSMutableArray *_stoppedFetchersToWaitFor;
}

@synthesize maxRunningFetchersPerHost = _maxRunningFetchersPerHost,
            configuration = _configuration,
            configurationBlock = _configurationBlock,
            cookieStorage = _cookieStorage,
            userAgent = _userAgent,
            callbackQueue = _callbackQueue,
            credential = _credential,
            proxyCredential = _proxyCredential,
            allowedInsecureSchemes = _allowedInsecureSchemes,
            allowLocalhostRequest = _allowLocalhostRequest,
            allowInvalidServerCertificates = _allowInvalidServerCertificates,
            unusedSessionTimeout = _unusedSessionTimeout;

- (instancetype)init {
  self = [super init];
  if (self) {
    _delayedFetchersByHost = [[NSMutableDictionary alloc] init];
    _runningFetchersByHost = [[NSMutableDictionary alloc] init];
    _maxRunningFetchersPerHost = 10;
    _cookieStorageMethod = -1;
    _unusedSessionTimeout = 60.0;
    _delegateDispatcher =
        [[GTMSessionFetcherSessionDelegateDispatcher alloc] initWithParentService:self
                                                           sessionDiscardInterval:_unusedSessionTimeout];
  }
  return self;
}

- (void)dealloc {
  [self detachAuthorizer];
  [_delegateDispatcher abandon];
}

#pragma mark Generate a new fetcher

- (id)fetcherWithRequest:(NSURLRequest *)request
            fetcherClass:(Class)fetcherClass {
  GTMSessionFetcher *fetcher = [[fetcherClass alloc] initWithRequest:request
                                                       configuration:self.configuration];
  if (self.callbackQueue) {
    fetcher.callbackQueue = self.callbackQueue;
  }
  fetcher.credential = self.credential;
  fetcher.proxyCredential = self.proxyCredential;
  fetcher.authorizer = self.authorizer;
  fetcher.cookieStorage = self.cookieStorage;
  fetcher.allowedInsecureSchemes = self.allowedInsecureSchemes;
  fetcher.allowLocalhostRequest = self.allowLocalhostRequest;
  fetcher.allowInvalidServerCertificates = self.allowInvalidServerCertificates;
  fetcher.configurationBlock = self.configurationBlock;
  fetcher.service = self;
  if (self.cookieStorageMethod >= 0) {
    [fetcher setCookieStorageMethod:self.cookieStorageMethod];
  }

  NSString *userAgent = self.userAgent;
  if ([userAgent length] > 0
      && [request valueForHTTPHeaderField:@"User-Agent"] == nil) {
    [fetcher.mutableRequest setValue:userAgent
                  forHTTPHeaderField:@"User-Agent"];
  }
  fetcher.testBlock = self.testBlock;

  return fetcher;
}

- (GTMSessionFetcher *)fetcherWithRequest:(NSURLRequest *)request {
  return [self fetcherWithRequest:request
                     fetcherClass:[GTMSessionFetcher class]];
}

- (GTMSessionFetcher *)fetcherWithURL:(NSURL *)requestURL {
  return [self fetcherWithRequest:[NSURLRequest requestWithURL:requestURL]];
}

- (GTMSessionFetcher *)fetcherWithURLString:(NSString *)requestURLString {
  return [self fetcherWithURL:[NSURL URLWithString:requestURLString]];
}

// Returns a session for the fetcher's host, or nil.
- (NSURLSession *)session {
  @synchronized(self) {
    NSURLSession *session = _delegateDispatcher.session;
    return session;
  }
}

- (id<NSURLSessionDelegate>)sessionDelegate {
  @synchronized(self) {
    return _delegateDispatcher;
  }
}

#pragma mark Queue Management

- (void)addRunningFetcher:(GTMSessionFetcher *)fetcher
                  forHost:(NSString *)host {
  // Add to the array of running fetchers for this host, creating the array if needed.
  NSMutableArray *runningForHost = [_runningFetchersByHost objectForKey:host];
  if (runningForHost == nil) {
    runningForHost = [NSMutableArray arrayWithObject:fetcher];
    [_runningFetchersByHost setObject:runningForHost forKey:host];
  } else {
    [runningForHost addObject:fetcher];
  }
}

- (void)addDelayedFetcher:(GTMSessionFetcher *)fetcher
                  forHost:(NSString *)host {
  // Add to the array of delayed fetchers for this host, creating the array if needed.
  NSMutableArray *delayedForHost = [_delayedFetchersByHost objectForKey:host];
  if (delayedForHost == nil) {
    delayedForHost = [NSMutableArray arrayWithObject:fetcher];
    [_delayedFetchersByHost setObject:delayedForHost forKey:host];
  } else {
    [delayedForHost addObject:fetcher];
  }
}

- (BOOL)isDelayingFetcher:(GTMSessionFetcher *)fetcher {
  @synchronized(self) {
    NSString *host = [[[fetcher mutableRequest] URL] host];
    if (host == nil) {
      return NO;
    }
    NSArray *delayedForHost = [_delayedFetchersByHost objectForKey:host];
    NSUInteger idx = [delayedForHost indexOfObjectIdenticalTo:fetcher];
    BOOL isDelayed = (delayedForHost != nil) && (idx != NSNotFound);
    return isDelayed;
  }
}

- (BOOL)fetcherShouldBeginFetching:(GTMSessionFetcher *)fetcher {
  // Entry point from the fetcher
  @synchronized(self) {
    NSURL *requestURL = [[fetcher mutableRequest] URL];
    NSString *host = [requestURL host];

    // Addresses "file:///path" case where localhost is the implicit host.
    if ([host length] == 0 && [requestURL isFileURL]) {
      host = @"localhost";
    }

    if ([host length] == 0) {
      // Data URIs legitimately have no host, reject other hostless URLs.
      GTMSESSION_ASSERT_DEBUG([[requestURL scheme] isEqual:@"data"], @"%@ lacks host", fetcher);
      return YES;
    }

    NSMutableArray *runningForHost = [_runningFetchersByHost objectForKey:host];
    if (runningForHost != nil
        && [runningForHost indexOfObjectIdenticalTo:fetcher] != NSNotFound) {
      GTMSESSION_ASSERT_DEBUG(NO, @"%@ was already running", fetcher);
      return YES;
    }

    // We'll save the host that serves as the key for this fetcher's array
    // to avoid any chance of the underlying request changing, stranding
    // the fetcher in the wrong array
    fetcher.serviceHost = host;

    if (fetcher.useBackgroundSession
        || _maxRunningFetchersPerHost == 0
        || _maxRunningFetchersPerHost >
           [[self class] numberOfNonBackgroundSessionFetchers:runningForHost]) {
      [self addRunningFetcher:fetcher forHost:host];
      return YES;
    } else {
      [self addDelayedFetcher:fetcher forHost:host];
      return NO;
    }
  }
  return YES;
}

- (void)startFetcher:(GTMSessionFetcher *)fetcher {
  [fetcher beginFetchMayDelay:NO
                 mayAuthorize:YES];
}

// Internal utility. Returns a fetcher's delegate if it's a dispatcher, or nil if the fetcher
// is its own delegate and has no dispatcher.
//
// Do not call this inside @synchronized(self).
- (GTMSessionFetcherSessionDelegateDispatcher *)delegateDispatcherForFetcher:(GTMSessionFetcher *)fetcher {
  NSURLSession *fetcherSession = fetcher.session;
  if (fetcherSession) {
    id<NSURLSessionDelegate> fetcherDelegate = fetcherSession.delegate;
    BOOL hasDispatcher = (fetcherDelegate != nil && fetcherDelegate != fetcher);
    if (hasDispatcher) {
      GTMSESSION_ASSERT_DEBUG([fetcherDelegate isKindOfClass:[GTMSessionFetcherSessionDelegateDispatcher class]],
                              @"Fetcher delegate class: %@", [fetcherDelegate class]);
      return (GTMSessionFetcherSessionDelegateDispatcher *)fetcherDelegate;
    }
  }
  return nil;
}

- (void)fetcherDidCreateSession:(GTMSessionFetcher *)fetcher {
  if (fetcher.canShareSession) {
    NSURLSession *fetcherSession = fetcher.session;
    GTMSESSION_ASSERT_DEBUG(fetcherSession != nil, @"Fetcher missing its session: %@", fetcher);

    GTMSessionFetcherSessionDelegateDispatcher *delegateDispatcher =
        [self delegateDispatcherForFetcher:fetcher];
    if (delegateDispatcher) {
      GTMSESSION_ASSERT_DEBUG(delegateDispatcher.session == nil,
                              @"Fetcher made an extra session: %@", fetcher);

      // Save this fetcher's session.
      delegateDispatcher.session = fetcherSession;
    }
  }
}

- (void)fetcherDidBeginFetching:(GTMSessionFetcher *)fetcher {
  // If this fetcher has a separate delegate with a shared session, then
  // this fetcher should be added to the delegate's map of tasks to fetchers.
  GTMSessionFetcherSessionDelegateDispatcher *delegateDispatcher =
      [self delegateDispatcherForFetcher:fetcher];
  if (delegateDispatcher) {
    GTMSESSION_ASSERT_DEBUG(fetcher.canShareSession,
                            @"Inappropriate shared session: %@", fetcher);

    // There should already be a session, from this or a previous fetcher.
    //
    // Sanity check that the fetcher's session is the delegate's shared session.
    NSURLSession *sharedSession = delegateDispatcher.session;
    NSURLSession *fetcherSession = fetcher.session;
    GTMSESSION_ASSERT_DEBUG(sharedSession != nil, @"Missing delegate session: %@", fetcher);
    GTMSESSION_ASSERT_DEBUG(fetcherSession == sharedSession, @"Inconsistent session: %@", fetcher);

    if (sharedSession != nil && fetcherSession == sharedSession) {
      NSURLSessionTask *task = fetcher.sessionTask;
      [delegateDispatcher setFetcher:fetcher
                             forTask:task];
    }
  }
}

- (void)stopFetcher:(GTMSessionFetcher *)fetcher {
  [fetcher stopFetching];
}

- (void)fetcherDidStop:(GTMSessionFetcher *)fetcher {
  // Entry point from the fetcher
  NSString *host = fetcher.serviceHost;
  if (!host) {
    // fetcher has been stopped previously
    return;
  }

  // This removeFetcher: invocation is a fallback; typically, fetchers are removed from the task
  // map when the task completes.
  GTMSessionFetcherSessionDelegateDispatcher *delegateDispatcher =
      [self delegateDispatcherForFetcher:fetcher];
  [delegateDispatcher removeFetcher:fetcher];

  @synchronized(self) {
    // If a test is waiting for all fetchers to stop, it needs to wait for this one
    // to invoke its callbacks on the callback queue.
    [_stoppedFetchersToWaitFor addObject:fetcher];

    NSMutableArray *runningForHost = [_runningFetchersByHost objectForKey:host];
    [runningForHost removeObject:fetcher];

    NSMutableArray *delayedForHost = [_delayedFetchersByHost objectForKey:host];
    [delayedForHost removeObject:fetcher];

    while ([delayedForHost count] > 0
           && [[self class] numberOfNonBackgroundSessionFetchers:runningForHost]
              < _maxRunningFetchersPerHost) {
      // Start another delayed fetcher running, scanning for the minimum
      // priority value, defaulting to FIFO for equal priorities
      GTMSessionFetcher *nextFetcher = nil;
      for (GTMSessionFetcher *delayedFetcher in delayedForHost) {
        if (nextFetcher == nil
            || delayedFetcher.servicePriority < nextFetcher.servicePriority) {
          nextFetcher = delayedFetcher;
        }
      }

      if (nextFetcher) {
        [self addRunningFetcher:nextFetcher forHost:host];
        runningForHost = [_runningFetchersByHost objectForKey:host];

        [delayedForHost removeObjectIdenticalTo:nextFetcher];
        [self startFetcher:nextFetcher];
      }
    }

    if ([runningForHost count] == 0) {
      // None left; remove the empty array
      [_runningFetchersByHost removeObjectForKey:host];
    }

    if ([delayedForHost count] == 0) {
      [_delayedFetchersByHost removeObjectForKey:host];
    }
  }
  // The fetcher is no longer in the running or the delayed array,
  // so remove its host and thread properties
  fetcher.serviceHost = nil;
}

- (NSUInteger)numberOfFetchers {
  @synchronized(self) {
    NSUInteger running = [self numberOfRunningFetchers];
    NSUInteger delayed = [self numberOfDelayedFetchers];
    return running + delayed;
  }
}

- (NSUInteger)numberOfRunningFetchers {
  @synchronized(self) {
    NSUInteger sum = 0;
    for (NSString *host in _runningFetchersByHost) {
      NSArray *fetchers = [_runningFetchersByHost objectForKey:host];
      sum += [fetchers count];
    }
    return sum;
  }
}

- (NSUInteger)numberOfDelayedFetchers {
  @synchronized(self) {
    NSUInteger sum = 0;
    for (NSString *host in _delayedFetchersByHost) {
      NSArray *fetchers = [_delayedFetchersByHost objectForKey:host];
      sum += [fetchers count];
    }
    return sum;
  }
}

- (NSArray *)issuedFetchers {
  @synchronized(self) {
    NSMutableArray *allFetchers = [NSMutableArray array];
    void (^accumulateFetchers)(id, id, BOOL *) = ^(NSString *host,
                                                   NSArray *fetchersForHost,
                                                   BOOL *stop) {
        [allFetchers addObjectsFromArray:fetchersForHost];
    };
    [_runningFetchersByHost enumerateKeysAndObjectsUsingBlock:accumulateFetchers];
    [_delayedFetchersByHost enumerateKeysAndObjectsUsingBlock:accumulateFetchers];

    GTMSESSION_ASSERT_DEBUG([allFetchers count] == [[NSSet setWithArray:allFetchers] count],
                            @"Fetcher appears multiple times\n running: %@\n delayed: %@",
                            _runningFetchersByHost, _delayedFetchersByHost);

    return [allFetchers count] > 0 ? allFetchers : nil;
  }
}

- (NSArray *)issuedFetchersWithRequestURL:(NSURL *)requestURL {
  NSString *host = [requestURL host];
  if ([host length] == 0) return nil;

  NSURL *targetURL = [requestURL absoluteURL];

  NSArray *allFetchers = [self issuedFetchers];
  NSIndexSet *indexes = [allFetchers indexesOfObjectsPassingTest:^BOOL(id fetcher,
                                                                       NSUInteger idx,
                                                                       BOOL *stop) {
      NSURL *fetcherURL = [[[fetcher mutableRequest] URL] absoluteURL];
      return [fetcherURL isEqual:targetURL];
  }];

  NSArray *result = nil;
  if ([indexes count] > 0) {
    result = [allFetchers objectsAtIndexes:indexes];
  }
  return result;
}

- (void)stopAllFetchers {
  @synchronized(self) {
    // Remove fetchers from the delayed list to avoid fetcherDidStop: from
    // starting more fetchers running as a side effect of stopping one
    NSArray *delayedFetchersByHost = [_delayedFetchersByHost allValues];
    [_delayedFetchersByHost removeAllObjects];

    for (NSArray *delayedForHost in delayedFetchersByHost) {
      for (GTMSessionFetcher *fetcher in delayedForHost) {
        [self stopFetcher:fetcher];
      }
    }

    NSArray *runningFetchersByHost = [_runningFetchersByHost allValues];
    [_runningFetchersByHost removeAllObjects];

    for (NSArray *runningForHost in runningFetchersByHost) {
      for (GTMSessionFetcher *fetcher in runningForHost) {
        [self stopFetcher:fetcher];
      }
    }
  }
}

#pragma mark Accessors

- (BOOL)reuseSession {
  @synchronized(self) {
    return _delegateDispatcher != nil;
  }
}

- (void)setReuseSession:(BOOL)shouldReuse {
  @synchronized(self) {
    BOOL wasReusing = (_delegateDispatcher != nil);
    if (shouldReuse != wasReusing) {
      [self abandonDispatcher];
      if (shouldReuse) {
        _delegateDispatcher =
            [[GTMSessionFetcherSessionDelegateDispatcher alloc] initWithParentService:self
                                                               sessionDiscardInterval:_unusedSessionTimeout];
      } else {
        _delegateDispatcher = nil;
      }
    }
  }
}

- (void)resetSession {
  @synchronized(self) {
    // The old dispatchers may be retained as delegates of any ongoing sessions by those sessions.
    if (_delegateDispatcher) {
      [self abandonDispatcher];
      _delegateDispatcher =
          [[GTMSessionFetcherSessionDelegateDispatcher alloc] initWithParentService:self
                                                             sessionDiscardInterval:_unusedSessionTimeout];
    }
  }
}

- (NSTimeInterval)unusedSessionTimeout {
  @synchronized(self) {
    return _unusedSessionTimeout;
  }
}

- (void)setUnusedSessionTimeout:(NSTimeInterval)timeout {
  @synchronized(self) {
    _unusedSessionTimeout = timeout;
    _delegateDispatcher.discardInterval = timeout;
  }
}

// This method should be called inside of @synchronized(self)
- (void)abandonDispatcher {
  [_delegateDispatcher abandon];
}

- (NSDictionary *)runningFetchersByHost {
  @synchronized(self) {
    return _runningFetchersByHost;
  }
}

- (void)setRunningFetchersByHost:(NSDictionary *)dict {
  @synchronized(self) {
    _runningFetchersByHost = [dict mutableCopy];
  }
}

- (NSDictionary *)delayedFetchersByHost {
  @synchronized(self) {
    return _delayedFetchersByHost;
  }
}

- (void)setDelayedFetchersByHost:(NSDictionary *)dict {
  @synchronized(self) {
    _delayedFetchersByHost = [dict mutableCopy];
  }
}

- (id<GTMFetcherAuthorizationProtocol>)authorizer {
  @synchronized(self) {
    return _authorizer;
  }
}

- (void)setAuthorizer:(id<GTMFetcherAuthorizationProtocol>)obj {
  @synchronized(self) {
    if (obj != _authorizer) {
      [self detachAuthorizer];
    }

    _authorizer = obj;
  }

  // Use the fetcher service for the authorization fetches if the auth
  // object supports fetcher services
  if ([obj respondsToSelector:@selector(setFetcherService:)]) {
#if GTM_USE_SESSION_FETCHER
    [obj setFetcherService:self];
#else
    [obj setFetcherService:(id)self];
#endif
  }
}

// This should be called inside a @synchronized(self) block.
- (void)detachAuthorizer {
  // This method is called by the fetcher service's dealloc and setAuthorizer:
  // methods; do not override.
  //
  // The fetcher service retains the authorizer, and the authorizer has a
  // weak pointer to the fetcher service (a non-zeroing pointer for
  // compatibility with iOS 4 and Mac OS X 10.5/10.6.)
  //
  // When this fetcher service no longer uses the authorizer, we want to remove
  // the authorizer's dependence on the fetcher service.  Authorizers can still
  // function without a fetcher service.
  if ([_authorizer respondsToSelector:@selector(fetcherService)]) {
    id authFetcherService = [_authorizer fetcherService];
    if (authFetcherService == self) {
      [_authorizer setFetcherService:nil];
    }
  }
}

- (NSOperationQueue *)delegateQueue {
  // Provided for compatibility with the old fetcher service.  The gtm-oauth2 code respects
  // any custom delegate queue for calling the app.
  return nil;
}

+ (NSUInteger)numberOfNonBackgroundSessionFetchers:(NSArray *)fetchers {
  NSUInteger sum = 0;
  for (GTMSessionFetcher *fetcher in fetchers) {
    if (!fetcher.useBackgroundSession) {
      ++sum;
    }
  }
  return sum;
}

@end

@implementation GTMSessionFetcherService (TestingSupport)

+ (instancetype)mockFetcherServiceWithFakedData:(NSData *)fakedDataOrNil
                                     fakedError:(NSError *)fakedErrorOrNil {
  NSHTTPURLResponse *fakedResponse =
      [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"http://example.invalid"]
                                  statusCode:(fakedErrorOrNil ? 500 : 200)
                                 HTTPVersion:@"HTTP/1.1"
                                headerFields:nil];
  GTMSessionFetcherService *service = [[self alloc] init];
  service.allowedInsecureSchemes = @[ @"http" ];
  service.testBlock = ^(GTMSessionFetcher *fetcherToTest,
                        GTMSessionFetcherTestResponse testResponse) {
    testResponse(fakedResponse, fakedDataOrNil, fakedErrorOrNil);
  };
  return service;
}

#pragma mark Synchronous Wait for Unit Testing

- (BOOL)waitForCompletionOfAllFetchersWithTimeout:(NSTimeInterval)timeoutInSeconds {
  NSDate *giveUpDate = [NSDate dateWithTimeIntervalSinceNow:timeoutInSeconds];
  _stoppedFetchersToWaitFor = [NSMutableArray array];

  BOOL shouldSpinRunLoop = [NSThread isMainThread];
  const NSTimeInterval kSpinInterval = 0.001;
  BOOL didTimeOut = NO;
  while (([self numberOfFetchers] > 0 || [_stoppedFetchersToWaitFor count] > 0)) {
    didTimeOut = [giveUpDate timeIntervalSinceNow] < 0;
    if (didTimeOut) break;

    GTMSessionFetcher *stoppedFetcher = [_stoppedFetchersToWaitFor firstObject];
    if (stoppedFetcher) {
      [_stoppedFetchersToWaitFor removeObject:stoppedFetcher];
      [stoppedFetcher waitForCompletionWithTimeout:10.0 * kSpinInterval];
    }

    if (shouldSpinRunLoop) {
      NSDate *stopDate = [NSDate dateWithTimeIntervalSinceNow:kSpinInterval];
      [[NSRunLoop currentRunLoop] runUntilDate:stopDate];
    } else {
      [NSThread sleepForTimeInterval:kSpinInterval];
    }
  }
  _stoppedFetchersToWaitFor = nil;

  return !didTimeOut;
}

@end

@implementation GTMSessionFetcherService (BackwardsCompatibilityOnly)

- (NSInteger)cookieStorageMethod {
  @synchronized(self) {
    return _cookieStorageMethod;
  }
}

- (void)setCookieStorageMethod:(NSInteger)cookieStorageMethod {
  @synchronized(self) {
    _cookieStorageMethod = cookieStorageMethod;
  }
}

@end

@implementation GTMSessionFetcherSessionDelegateDispatcher {
  __weak GTMSessionFetcherService *_parentService;
  NSURLSession *_session;
  // The task map maps NSURLSessionTasks to GTMSessionFetchers
  NSMutableDictionary *_taskToFetcherMap;
  // The discard timer will invalidate sessions after the session's last task completes.
  NSTimer *_discardTimer;
  NSTimeInterval _discardInterval;
}

- (instancetype)init {
  [self doesNotRecognizeSelector:_cmd];
  return nil;
}

- (instancetype)initWithParentService:(GTMSessionFetcherService *)parentService
               sessionDiscardInterval:(NSTimeInterval)discardInterval {
  self = [super init];
  if (self) {
    _discardInterval = discardInterval;
    _parentService = parentService;
  }
  return self;
}

- (NSString *)description {
  return [NSString stringWithFormat:@"%@ %p %@ %@",
          [self class], self,
          _session ?: @"<no session>",
          [_taskToFetcherMap count] > 0 ? _taskToFetcherMap : @"<no tasks>"];
}

// This method should be called inside of a @synchronized(self) block.
- (void)startDiscardTimer {
  [_discardTimer invalidate];
  _discardTimer = nil;
  if (_discardInterval > 0) {
    _discardTimer = [NSTimer timerWithTimeInterval:_discardInterval
                                            target:self
                                          selector:@selector(discardTimerFired:)
                                          userInfo:nil
                                           repeats:NO];
    [_discardTimer setTolerance:(_discardInterval / 10)];
    [[NSRunLoop mainRunLoop] addTimer:_discardTimer forMode:NSRunLoopCommonModes];
  }
}

// This method should be called inside of a @synchronized(self) block.
- (void)destroyDiscardTimer {
  [_discardTimer invalidate];
  _discardTimer = nil;
}

- (void)discardTimerFired:(NSTimer *)timer {
  GTMSessionFetcherService *service;
  @synchronized(self) {
    NSUInteger numberOfTasks = [_taskToFetcherMap count];
    if (numberOfTasks == 0) {
      service = _parentService;
    }
  }
  // Ask the service to abandon us. It will create a new delegate dispatcher
  // which will have a distinct session.
  //
  // Since finishing this session takes a while, it's better for the service to have a new
  // delegate dispatcher while the tasks on this session's delegate dispatcher finish up.
  //
  // We want to call the service from outside of a @synchronized section.
  [service resetSession];
}

- (void)abandon {
  @synchronized(self) {
    [self destroySessionAndTimer];
  }
}

// This method should be called inside of a @synchronized(self) block.
- (void)destroySessionAndTimer {
  [self destroyDiscardTimer];

  // Break any retain cycle from the session holding the delegate.
  [_session finishTasksAndInvalidate];

  // Immediately clear the session so no new task may be issued with it.
  //
  // The _taskToFetcherMap needs to stay valid until the outstanding tasks finish.
  _session = nil;
}

- (void)setFetcher:(GTMSessionFetcher *)fetcher forTask:(NSURLSessionTask *)task {
  GTMSESSION_ASSERT_DEBUG(fetcher != nil, @"missing fetcher");

  @synchronized(self) {
    if (_taskToFetcherMap == nil) {
      _taskToFetcherMap = [[NSMutableDictionary alloc] init];
    }

    if (fetcher) {
      [_taskToFetcherMap setObject:fetcher forKey:task];
      [self destroyDiscardTimer];
    }
  }
}

- (void)removeFetcher:(GTMSessionFetcher *)fetcher {
  @synchronized(self) {
    // Typically, a fetcher should be removed when its task invokes
    // URLSession:task:didCompleteWithError:.
    //
    // When fetching with a testBlock, though, the task completed delegate
    // method may not be invoked, requiring cleanup here.
    NSArray *tasks = [_taskToFetcherMap allKeysForObject:fetcher];
    GTMSESSION_ASSERT_DEBUG([tasks count] <= 1, @"fetcher task not unmapped: %@", tasks);
    [_taskToFetcherMap removeObjectsForKeys:tasks];

    if ([_taskToFetcherMap count] == 0) {
      [self startDiscardTimer];
    }
  }
}

// This helper method provides synchronized access to the task map for the delegate
// methods below.
- (id)fetcherForTask:(NSURLSessionTask *)task {
  @synchronized(self) {
    return [_taskToFetcherMap objectForKey:task];
  }
}

- (void)removeTaskFromMap:(NSURLSessionTask *)task {
  @synchronized(self) {
    [_taskToFetcherMap removeObjectForKey:task];
  }
}

- (void)setSession:(NSURLSession *)session {
  @synchronized(self) {
    _session = session;
  }
}

- (NSURLSession *)session {
  @synchronized(self) {
    return _session;
  }
}

- (NSTimeInterval)discardInterval {
  @synchronized(self) {
    return _discardInterval;
  }
}

- (void)setDiscardInterval:(NSTimeInterval)interval {
  @synchronized(self) {
    _discardInterval = interval;
  }
}

// NSURLSessionDelegate protocol methods.

// - (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session;
//
// TODO(seh): How do we route this to an appropriate fetcher?


- (void)URLSession:(NSURLSession *)session didBecomeInvalidWithError:(NSError *)error {
  GTM_LOG_SESSION_DELEGATE(@"%@ %p URLSession:%@ didBecomeInvalidWithError:%@",
                           [self class], self, session, error);
  NSDictionary *localTaskToFetcherMap;
  @synchronized(self) {
    _session = nil;

    localTaskToFetcherMap = [_taskToFetcherMap copy];
  }

  // Any "suspended" tasks may not have received callbacks from NSURLSession when the session
  // completes; we'll call them now.
  [localTaskToFetcherMap enumerateKeysAndObjectsUsingBlock:^(NSURLSessionTask *task,
                                                             GTMSessionFetcher *fetcher,
                                                             BOOL *stop) {
    if (fetcher.session == session) {
        // Our delegate method URLSession:task:didCompleteWithError: will rely on
        // _taskToFetcherMap so that should still contain this fetcher.
        NSError *canceledError = [NSError errorWithDomain:NSURLErrorDomain
                                                     code:NSURLErrorCancelled
                                                 userInfo:nil];
        [self URLSession:session task:task didCompleteWithError:canceledError];
      } else {
        GTMSESSION_ASSERT_DEBUG(0, @"Unexpected session in fetcher: %@ has %@ (expected %@)",
                                fetcher, fetcher.session, session);
      }
  }];

  // Our tests rely on this notification to know the session discard timer fired.
  NSDictionary *userInfo = @{ kGTMSessionFetcherServiceSessionKey : session };
  NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
  [nc postNotificationName:kGTMSessionFetcherServiceSessionBecameInvalidNotification
                    object:_parentService
                  userInfo:userInfo];
}


#pragma mark - NSURLSessionTaskDelegate

// NSURLSessionTaskDelegate protocol methods.
//
// We won't test here if the fetcher responds to these since we only want this
// class to implement the same delegate methods the fetcher does (so NSURLSession's
// tests for respondsToSelector: will have the same result whether the session
// delegate is the fetcher or this dispatcher.)

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))completionHandler {
  id<NSURLSessionTaskDelegate> fetcher = [self fetcherForTask:task];
  [fetcher URLSession:session
                 task:task
willPerformHTTPRedirection:response
           newRequest:request
    completionHandler:completionHandler];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))handler {
  id<NSURLSessionTaskDelegate> fetcher = [self fetcherForTask:task];
  [fetcher URLSession:session
                 task:task
  didReceiveChallenge:challenge
    completionHandler:handler];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
 needNewBodyStream:(void (^)(NSInputStream *bodyStream))handler {
  id<NSURLSessionTaskDelegate> fetcher = [self fetcherForTask:task];
  [fetcher URLSession:session
                 task:task
    needNewBodyStream:handler];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
   didSendBodyData:(int64_t)bytesSent
    totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend {
  id<NSURLSessionTaskDelegate> fetcher = [self fetcherForTask:task];
  [fetcher URLSession:session
                 task:task
      didSendBodyData:bytesSent
       totalBytesSent:totalBytesSent
totalBytesExpectedToSend:totalBytesExpectedToSend];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
  id<NSURLSessionTaskDelegate> fetcher = [self fetcherForTask:task];

  // This is the usual way tasks are removed from the task map.
  [self removeTaskFromMap:task];

  [fetcher URLSession:session
                 task:task
 didCompleteWithError:error];
}

// NSURLSessionDataDelegate protocol methods.

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))handler {
  id<NSURLSessionDataDelegate> fetcher = [self fetcherForTask:dataTask];
  [fetcher URLSession:session
             dataTask:dataTask
   didReceiveResponse:response
    completionHandler:handler];
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didBecomeDownloadTask:(NSURLSessionDownloadTask *)downloadTask {
  id<NSURLSessionDataDelegate> fetcher = [self fetcherForTask:dataTask];
  GTMSESSION_ASSERT_DEBUG(fetcher != nil, @"Missing fetcher for %@", dataTask);
  [self removeTaskFromMap:dataTask];
  if (fetcher) {
    GTMSESSION_ASSERT_DEBUG([fetcher isKindOfClass:[GTMSessionFetcher class]],
                            @"Expecting GTMSessionFetcher");
    [self setFetcher:(GTMSessionFetcher *)fetcher forTask:downloadTask];
  }

  [fetcher URLSession:session
             dataTask:dataTask
didBecomeDownloadTask:downloadTask];
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
  id<NSURLSessionDataDelegate> fetcher = [self fetcherForTask:dataTask];
  [fetcher URLSession:session
             dataTask:dataTask
       didReceiveData:data];
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
 willCacheResponse:(NSCachedURLResponse *)proposedResponse
 completionHandler:(void (^)(NSCachedURLResponse *))handler {
  id<NSURLSessionDataDelegate> fetcher = [self fetcherForTask:dataTask];
  [fetcher URLSession:session
             dataTask:dataTask
    willCacheResponse:proposedResponse
    completionHandler:handler];
}

// NSURLSessionDownloadDelegate protocol methods.

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
  id<NSURLSessionDownloadDelegate> fetcher = [self fetcherForTask:downloadTask];
  [fetcher URLSession:session
         downloadTask:downloadTask
didFinishDownloadingToURL:location];
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalWritten
totalBytesExpectedToWrite:(int64_t)totalExpected {
  id<NSURLSessionDownloadDelegate> fetcher = [self fetcherForTask:downloadTask];
  [fetcher URLSession:session
         downloadTask:downloadTask
         didWriteData:bytesWritten
    totalBytesWritten:totalWritten
totalBytesExpectedToWrite:totalExpected];
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didResumeAtOffset:(int64_t)fileOffset
expectedTotalBytes:(int64_t)expectedTotalBytes {
  id<NSURLSessionDownloadDelegate> fetcher = [self fetcherForTask:downloadTask];
  [fetcher URLSession:session
         downloadTask:downloadTask
    didResumeAtOffset:fileOffset
   expectedTotalBytes:expectedTotalBytes];
}

@end
