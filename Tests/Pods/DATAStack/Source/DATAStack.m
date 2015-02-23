#import "DATAStack.h"

@import UIKit;

@interface DATAStack ()

@property (strong, nonatomic, readwrite) NSManagedObjectContext *mainContext;
@property (strong, nonatomic, readwrite) NSManagedObjectContext *disposableMainContext;
@property (strong, nonatomic) NSManagedObjectContext *writerContext;
@property (strong, nonatomic) NSPersistentStoreCoordinator *persistentStoreCoordinator;
@property (strong, nonatomic) NSPersistentStoreCoordinator *disposablePersistentStoreCoordinator;

@property (nonatomic) DATAStackStoreType storeType;
@property (nonatomic, copy) NSString *modelName;
@property (nonatomic, strong) NSBundle *modelBundle;

@end

@implementation DATAStack

#pragma mark - Initializers

- (instancetype)init
{
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *bundleName = [[bundle infoDictionary] objectForKey:@"CFBundleName"];

    return [self initWithModelName:bundleName];
}

- (instancetype)initWithModelName:(NSString *)modelName
{
    NSBundle *bundle = [NSBundle mainBundle];

    return [self initWithModelName:modelName
                            bundle:bundle
                         storeType:DATAStackSQLiteStoreType];
}

- (instancetype)initWithModelName:(NSString *)modelName
                           bundle:(NSBundle *)bundle
                        storeType:(DATAStackStoreType)storeType
{
    self = [super init];
    if (!self) return nil;

    _modelName = modelName;
    _modelBundle = bundle;
    _storeType = storeType;

    if (!self.persistentStoreCoordinator) NSLog(@"Error setting up data stack");

    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSManagedObjectContextDidSaveNotification
                                                  object:nil];
}

#pragma mark - Getters

- (NSManagedObjectContext *)mainContext
{
    if (_mainContext) return _mainContext;

    _mainContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
    _mainContext.undoManager = nil;
    _mainContext.parentContext = self.writerContext;
    _mainContext.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy;

    return _mainContext;
}

- (NSManagedObjectContext *)writerContext
{
    if (_writerContext) return _writerContext;

    _writerContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    _writerContext.undoManager = nil;
    _writerContext.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy;
    _writerContext.persistentStoreCoordinator = self.persistentStoreCoordinator;

    return _writerContext;
}

- (NSPersistentStoreCoordinator *)persistentStoreCoordinator
{
    if (_persistentStoreCoordinator) return _persistentStoreCoordinator;

    NSString *filePath = [NSString stringWithFormat:@"%@.sqlite", self.modelName];
    NSURL *storeURL = [[self applicationDocumentsDirectory] URLByAppendingPathComponent:filePath];

    NSDictionary *options = @{ NSMigratePersistentStoresAutomaticallyOption: @YES,
                               NSInferMappingModelAutomaticallyOption: @YES };

    NSString *storeType;

    switch (self.storeType) {
        case DATAStackInMemoryStoreType: {
            storeType = NSInMemoryStoreType;
            storeURL = nil;
            options = nil;
        } break;
        case DATAStackSQLiteStoreType:
            storeType = NSSQLiteStoreType;
            break;
    }

    NSBundle *bundle = (self.modelBundle) ?: [NSBundle mainBundle];
    NSURL *modelURL = [bundle URLForResource:self.modelName withExtension:@"momd"];
    if (!modelURL) {
        NSLog(@"Model with model name {%@} not found in bundle {%@}", self.modelName, bundle);
        abort();
    }

    NSManagedObjectModel *model = [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL];
    _persistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];

    NSError *addPersistentStoreError = nil;
    if (![_persistentStoreCoordinator addPersistentStoreWithType:storeType
                                                   configuration:nil
                                                             URL:storeURL
                                                         options:options
                                                           error:&addPersistentStoreError]) {

        [[NSFileManager defaultManager] removeItemAtPath:storeURL.path error:nil];
        if (![_persistentStoreCoordinator addPersistentStoreWithType:storeType
                                                       configuration:nil
                                                                 URL:storeURL
                                                             options:options
                                                               error:&addPersistentStoreError]) {
            NSLog(@"Unresolved error %@, %@", addPersistentStoreError, [addPersistentStoreError userInfo]);
            abort();
        }

        NSString *alertTitle = NSLocalizedString(@"Error encountered while reading the database. Please allow all the data to download again.", @"[Error] Message to show when the database is corrupted");
        [[[UIAlertView alloc] initWithTitle:alertTitle
                                    message:nil
                                   delegate:nil
                          cancelButtonTitle:@"OK"
                          otherButtonTitles:nil] show];
    }

#if !TARGET_IPHONE_SIMULATOR
    NSError *excludeSQLiteFileFromBackupsError = nil;
    if (![storeURL setResourceValue:@YES
                             forKey:NSURLIsExcludedFromBackupKey
                              error:&excludeSQLiteFileFromBackupsError]) {
        NSLog(@"Excluding SQLite file from backup caused an error: %@", [excludeSQLiteFileFromBackupsError description]);
    };
#endif

    return _persistentStoreCoordinator;
}

- (NSPersistentStoreCoordinator *)disposablePersistentStoreCoordinator
{
    if (_disposablePersistentStoreCoordinator) return _disposablePersistentStoreCoordinator;

    NSBundle *bundle = (self.modelBundle) ?: [NSBundle mainBundle];
    NSURL *modelURL = [bundle URLForResource:self.modelName withExtension:@"momd"];
    if (!modelURL) {
        NSLog(@"Model with model name {%@} not found in bundle {%@}", self.modelName, bundle);
        abort();
    }

    NSManagedObjectModel *model = [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL];
    _disposablePersistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];

    return _disposablePersistentStoreCoordinator;
}

#pragma mark - Private methods

- (void)persistWithCompletion:(void (^)())completion
{
    NSManagedObjectContext *writerManagedObjectContext = self.writerContext;
    NSManagedObjectContext *managedObjectContext = self.mainContext;

    [managedObjectContext performBlock:^{
        NSError *error = nil;
        if ([managedObjectContext save:&error]) {
            [writerManagedObjectContext performBlock:^{
                NSError *parentError = nil;
                if ([writerManagedObjectContext save:&parentError]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (completion) completion();
                    });
                } else {
                    NSLog(@"Unresolved error saving parent managed object context %@, %@", error, [error userInfo]);
                    abort();
                }
            }];
        } else {
            NSLog(@"Unresolved error saving managed object context %@, %@", error, [error userInfo]);
            abort();
        }
    }];
}

#pragma mark - Application's Documents directory

- (NSURL *)applicationDocumentsDirectory
{
    return [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory
                                                   inDomains:NSUserDomainMask] lastObject];
}

#pragma mark - Public methods

- (void)performInNewBackgroundContext:(void (^)(NSManagedObjectContext *backgroundContext))operation
{
    NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    context.persistentStoreCoordinator = self.persistentStoreCoordinator;
    context.undoManager = nil;
    context.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(backgroundContextDidSave:)
                                                 name:NSManagedObjectContextDidSaveNotification
                                               object:context];

    [context performBlock:^{
        if (operation) operation(context);
    }];
}

- (NSManagedObjectContext *)disposableMainContext
{
    if (_disposableMainContext) return _disposableMainContext;

    _disposableMainContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
    _disposableMainContext.persistentStoreCoordinator = self.disposablePersistentStoreCoordinator;

    return _disposableMainContext;
}

#pragma mark - Observers

- (void)backgroundContextDidSave:(NSNotification *)backgroundContextNotification
{
    if ([NSThread isMainThread]) {
        [NSException raise:@"DATASTACK_BACKGROUND_CONTEXT_CREATION_EXCEPTION"
                    format:@"Background context saved in the main thread. Use context's `performBlock`"];
    } else {
        [self.mainContext performBlock:^{
            [self.mainContext mergeChangesFromContextDidSaveNotification:backgroundContextNotification];
        }];
    }
}

#pragma mark - Test

- (void)drop
{
    NSPersistentStore *store = [self.persistentStoreCoordinator.persistentStores lastObject];
    NSURL *storeURL = store.URL;

    self.writerContext = nil;
    self.mainContext = nil;
    self.persistentStoreCoordinator = nil;

    NSFileManager *fileManager = [NSFileManager defaultManager];

    NSError *error = nil;
    if ([fileManager fileExistsAtPath:storeURL.path]) [fileManager removeItemAtURL:storeURL error:&error];

    if (error) {
        NSLog(@"error deleting sqlite file");
        abort();
    }
}

@end