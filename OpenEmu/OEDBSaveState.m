/*
 Copyright (c) 2011, OpenEmu Team
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the OpenEmu Team nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "OEDBSaveState.h"
#import "OELibraryDatabase.h"
#import "OEDBRom.h"
#import "OEDBGame.h"
#import "OEDBSystem.h"
#import "OECorePlugin.h"

#import "NSURL+OELibraryAdditions.h"
#import "NSManagedObjectContext+OEAdditions.h"

// Preference keys
NSString *const OESaveStateUseQuickSaveSlotsKey = @"UseQuickSaveSlots";

// Required files
NSString *const OESaveStateSuffix = @"oesavestate";
NSString *const OESaveStateDataFile       = @"State";
NSString *const OESaveStateScreenshotFile = @"ScreenShot";
NSString *const OESaveStateLatestVersion  = @"1.0";

// Info.plist keys
NSString *const OESaveStateInfoVersionKey           = @"Version";
NSString *const OESaveStateInfoNameKey              = @"Name";
NSString *const OESaveStateInfoDescriptionKey       = @"Description";
NSString *const OESaveStateInfoROMMD5Key            = @"ROM MD5";
NSString *const OESaveStateInfoCoreIdentifierKey    = @"Core Identifier";
NSString *const OESaveStateInfoCoreVersionKey       = @"Core Version";
NSString *const OESaveStateInfoTimestampKey         = @"Timestamp";

// Special name constants
NSString *const OESaveStateSpecialNamePrefix    = @"OESpecialState_";
NSString *const OESaveStateAutosaveName         = @"OESpecialState_auto";
NSString *const OESaveStateQuicksaveName        = @"OESpecialState_quick";

@implementation OEDBSaveState

+ (OEDBSaveState *)saveStateWithURL:(NSURL *)url inContext:(NSManagedObjectContext *)context
{
    NSURL *saveStateDirectoryURL = [[context libraryDatabase] stateFolderURL];

    // normalize URL for lookup
    NSURL  *relativeURL = [url urlRelativeToURL:saveStateDirectoryURL];
    NSString *urlString = [self OE_stringByRemovingTrailingSlash:[relativeURL relativeString]];

    // query core data
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:[self entityName]];
    [request setPredicate:[NSPredicate predicateWithFormat:@"location == %@", urlString]];
    NSArray *results = [context executeFetchRequest:request error:nil];
    if([results count] >= 1)
    {
        NSLog(@"WARNING: Found several save states with the same URL!");
    }

    return [results lastObject];
}

+ (id)createSaveStateByImportingBundleURL:(NSURL *)url intoContext:(NSManagedObjectContext *)context
{
    // Check if state is already in database
    OEDBSaveState *state = [self saveStateWithURL:url inContext:context];
    if(state)
    {
        DLog(@"SaveState %@ is already in database", [state displayName]);
        return state;
    }

    // Check if url points to valid Save State
    NSString *fileName = [self OE_stringByRemovingTrailingSlash:[url lastPathComponent]];
    NSString *fileExtension = [fileName pathExtension];

    // Check url extension
    if([fileExtension isNotEqualTo:@"oesavestate"])
    {
        DLog(@"SaveState %@ has wrong extension (%@)", url, fileExtension);
        return nil;
    }

    // See if state and info.plist files are available
    NSError *error = nil;
    NSURL *dataURL = [self OE_dataURLWithBundleURL:url];
    NSURL *infoPlistURL = [self OE_infoPlistURLWithBundleURL:url];

    if(![dataURL checkResourceIsReachableAndReturnError:&error])
    {
        DLog(@"SaveState %@ has no data file", url);
        DLog(@"%@", error);
        return nil;
    }

    if(![infoPlistURL checkResourceIsReachableAndReturnError:&error])
    {
        DLog(@"SaveState %@ has no Info.plist file", url);
        DLog(@"%@", error);
        return nil;
    }

    // Create new object
    NSURL *standardizedURL = [url standardizedURL];
    state = [self createObjectInContext:context];
    [state setURL:standardizedURL];

    // Try to read Info.plist
    BOOL validBundle = [state readFromDisk];
    if(!validBundle)
    {
        DLog(@"SaveState %@ seems invalid after further inspection!", url);
        [state delete];
        return nil;
    }

    BOOL didMove = [state moveToDefaultLocation];
    if(!didMove)
    {
        DLog(@"SaveState %@ could not be moved!", url);
        [state delete];
        return nil;
    }

    [state save];
    return state;
}

+ (id)createSaveStateNamed:(NSString *)name forRom:(OEDBRom *)rom core:(OECorePlugin *)core withFile:(NSURL *)stateFileURL inContext:(NSManagedObjectContext *)context
{
    NSURL *dataFileURL = [stateFileURL standardizedURL];

    // Check supplied values
    if(![dataFileURL checkResourceIsReachableAndReturnError:nil])
    {
        DLog(@"State file does not exist!");
        return nil;
    }

    if(name == nil || [name length] == 0)
    {
        DLog(@"Invalid Save State name!");
        return nil;
    }

    if(rom == nil)
    {
        DLog(@"ROM is invalid!");
        return nil;
    }

    NSError *error      = nil;

    NSString *temporaryName = [NSString stringWithFormat:@"org.openemu.openemu/SaveState.%@", OESaveStateSuffix];
    NSString *temporaryPath = [NSTemporaryDirectory() stringByAppendingPathComponent:temporaryName];
    [[NSFileManager defaultManager] createDirectoryAtPath:temporaryPath withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *temporaryURL = [NSURL fileURLWithPath:temporaryPath isDirectory:NO];

    OEDBSaveState *savestate = [OEDBSaveState createObjectInContext:context];
    [savestate setName:name];
    [savestate setRom:rom];
    [savestate setCoreIdentifier:[core bundleIdentifier]];
    [savestate setCoreVersion:[core version]];
    [savestate setURL:temporaryURL];

    if(![[NSFileManager defaultManager] createDirectoryAtPath:[temporaryURL path] withIntermediateDirectories:YES attributes:nil error:&error])
    {
        DLog(@"Could not create save state bundle!");
        DLog(@"%@", error);

        [savestate delete];
        return nil;
    }

    if(![savestate writeToDisk])
    {
        DLog(@"Could not write Info.plist!");
        [savestate delete];
        return nil;
    }

    if(![savestate moveToDefaultLocation])
    {
        DLog(@"Could not move save state to default location!");
        [savestate delete];
        return nil;
    }

    [savestate save];
    return savestate;
}

+ (OEDBSaveState*)updateOrCreateStateWithURL:(NSURL *)url inContext:(NSManagedObjectContext *)context
{
    OEDBSaveState *saveState = [self createSaveStateByImportingBundleURL:url intoContext:context];

    [saveState readFromDisk];
    [saveState moveToDefaultLocation];
    [saveState save];

    if(![saveState isValid])
    {
        [saveState delete];
        saveState = nil;
    }

    return saveState;
}

+ (NSString *)nameOfQuickSaveInSlot:(NSInteger)slot
{
    return slot == 0 ? OESaveStateQuicksaveName:[NSString stringWithFormat:@"%@%ld", OESaveStateQuicksaveName, slot];
}

#pragma mark - OEDBItem Overrides
+ (instancetype)createObjectInContext:(NSManagedObjectContext *)context
{
    id result = [super createObjectInContext:context];
    [result setTimestamp:[NSDate date]];
    return result;
}

+ (NSString*)entityName
{
    return @"SaveState";
}
#pragma mark - Private Helpers
+ (NSString*)OE_stringByRemovingTrailingSlash:(NSString*)string
{
    if([string characterAtIndex:[string length]-1] == '/')
        return [string substringToIndex:[string length]-1];

    return string;
}

+ (NSURL*)OE_dataURLWithBundleURL:(NSURL*)url
{
    return [url URLByAppendingPathComponent:OESaveStateDataFile];
}

+ (NSURL*)OE_infoPlistURLWithBundleURL:(NSURL*)url
{
    return [url URLByAppendingPathComponent:@"Info.plist"];
}

+ (NSURL*)OE_screenShotURLWithBundleURL:(NSURL*)url
{
    return [url URLByAppendingPathComponent:OESaveStateScreenshotFile];
}
#pragma mark - Handling Bundle & Files
- (BOOL)writeToDisk
{
    NSURL *infoPlistURL = [self infoPlistURL];
    NSMutableDictionary *infoPlist = [NSMutableDictionary dictionary];

    NSString *name             = [self name];
    NSString *coreIdentifier   = [self coreIdentifier];
    NSString *md5Hash          = [[self rom] md5HashIfAvailable];

    NSString *coreVersion      = [self coreVersion];
    NSDate   *timestamp        = [self timestamp];
    NSString *userDescription  = [self userDescription];

    if(name == nil || [name length] == 0)
    {
        DLog(@"Save state is corrupted! Name is missing.");
        return NO;
    }
    if(coreIdentifier == nil || [coreIdentifier length] == 0)
    {
        DLog(@"Save state is corrupted! Core Identifier is invalid.");
        return NO;
    }
    if(md5Hash == nil || [md5Hash length] == 0)
    {
        DLog(@"Save state is corrupted! MD5Hash or rom are missing.");
        return NO;
    }

    [infoPlist setObject:name forKey:OESaveStateInfoNameKey];
    [infoPlist setObject:coreIdentifier forKey:OESaveStateInfoCoreIdentifierKey];
    [infoPlist setObject:md5Hash forKey:OESaveStateInfoROMMD5Key];
    [infoPlist setObject:OESaveStateLatestVersion forKey:OESaveStateInfoVersionKey];

    if(userDescription != nil)
        [infoPlist setObject:userDescription forKey:OESaveStateInfoDescriptionKey];
    if(coreVersion != nil)
        [infoPlist setObject:coreVersion forKey:OESaveStateInfoCoreVersionKey];
    if(timestamp != nil)
        [infoPlist setObject:timestamp forKey:OESaveStateInfoTimestampKey];

    if(![infoPlist writeToURL:infoPlistURL atomically:YES])
    {
        DLog(@"Unable to write Info.plist file!");
        return NO;
    }

    return YES;
}

- (BOOL)readFromDisk
{
    NSError *error   = nil;

    NSURL *infoPlistURL  = [self infoPlistURL];
    NSURL *dataURL       = [self dataFileURL];

    NSManagedObjectContext *context = [self managedObjectContext];

    // Read values from Info.plist
    NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfURL:infoPlistURL];
    if(infoPlist == nil)
    {
        DLog(@"Could not read Info.plist file! This state should be deleted!");
        return NO;
    }
    // First values are mandatory
    NSString *name = [infoPlist objectForKey:OESaveStateInfoNameKey];
    NSString *romMD5 = [infoPlist objectForKey:OESaveStateInfoROMMD5Key];
    NSString *coreIdentifier = [infoPlist objectForKey:OESaveStateInfoCoreIdentifierKey];
    // These values are kind of optional
    NSString *coreVersion = [infoPlist objectForKey:OESaveStateInfoCoreVersionKey];
    NSDate   *timestamp = [infoPlist objectForKey:OESaveStateInfoTimestampKey];
    NSString *version = [infoPlist objectForKey:OESaveStateInfoVersionKey];
    NSString *description = [infoPlist objectForKey:OESaveStateInfoDescriptionKey];

    // make sure we have a version (shouldn't be a problem),
    // and this OE version can handle it
    if(version == nil || [version length] == 0)
    {
        version = @"1.0";
    }

    if([version compare:OESaveStateLatestVersion] == NSOrderedDescending)
    {
        DLog(@"This version of OpenEmu only supports save states up to version %@. SaveState uses version %@ format", OESaveStateLatestVersion, version);
        return NO;
    }

    // in the future, we can start differentiating save state versions here

    // Check values for sanity
    if(name == nil || [name length] == 0)
    {
        DLog(@"Info.plist does not contain a valid name!");
        return NO;
    }

    if(romMD5 == nil || [romMD5 length] == 0)
    {
        DLog(@"Info.plist does not contain a valid rom reference!");
        return NO;
    }

    if(coreIdentifier == nil || [coreIdentifier length] == 0)
    {
        DLog(@"Info.plist does not contain a valid core reference!");
        return NO;
    }

    // Check additional files (data)
    if(![dataURL checkResourceIsReachableAndReturnError:&error])
    {
        DLog(@"Data file if missing!");
        DLog(@"%@", error);
        return NO;
    }

    // Make sure the rom file is available
    OEDBRom *rom = [OEDBRom romWithMD5HashString:romMD5 inContext:context error:&error];
    if(rom == nil)
    {
        DLog(@"Could not find ROM with MD5 hash %@", romMD5);
        DLog(@"%@", error);
        return NO;
    }

    // Set mandatory values
    [self setName:name];
    [self setRom:rom];
    [self setCoreIdentifier:coreIdentifier];

    // Set optional values
    if(coreVersion) [self setCoreVersion:coreVersion];
    if(description) [self setUserDescription:description];
    if(timestamp)   [self setTimestamp:timestamp];

    return YES;
}

- (BOOL)filesAvailable
{
    NSURL *bundleURL  = [self URL];
    NSURL *stateURL   = [self dataFileURL];
    NSURL *infoURL    = [self infoPlistURL];

    return [bundleURL checkResourceIsReachableAndReturnError:nil]
    && [stateURL checkResourceIsReachableAndReturnError:nil]
    && [infoURL checkResourceIsReachableAndReturnError:nil];
}

- (void)replaceStateFileWithFile:(NSURL *)stateFile
{
    NSError *error = nil;
    if(![[NSFileManager defaultManager] removeItemAtURL:[self dataFileURL] error:&error])
    {
        DLog(@"Could not delete previous state file!");
        DLog(@"%@", error);
    }

    if(![[NSFileManager defaultManager] moveItemAtURL:stateFile toURL:[self dataFileURL] error:&error])
    {
        DLog(@"Could not copy new state file");
        DLog(@"%@", error);
    }
}

- (BOOL)isValid
{
    if(!([self filesAvailable] && [self rom] != nil))
    {
        if([self rom] == nil)
            NSLog(@"%@", [self rom]);

        NSURL *bundleURL  = [self URL];
        NSURL *stateURL   = [self dataFileURL];
        NSURL *infoURL    = [self infoPlistURL];

        if(![bundleURL checkResourceIsReachableAndReturnError:nil])
            DLog(@"bundle missing: %@", bundleURL);
        if(![stateURL checkResourceIsReachableAndReturnError:nil])
            DLog(@"state missing: %@", stateURL);
        if(![infoURL checkResourceIsReachableAndReturnError:nil])
            DLog(@"info.plist missing: %@", infoURL);
    }
    return [self filesAvailable] && [self rom] != nil;
}
#pragma mark - Management
- (void)deleteAndRemoveFiles
{
    NSURL *url = [self URL];
    if(url)
        [[NSFileManager defaultManager] trashItemAtURL:url resultingItemURL:nil error:nil];
    [self delete];
    [self save];
}

- (void)deleteAndRemoveFilesIfInvalid
{
    if(![self isValid])
        [self deleteAndRemoveFiles];
}

- (BOOL)moveToDefaultLocation
{
    OEDBRom *rom = [self rom];
    NSURL *saveStateDirectoryURL = [[self libraryDatabase] stateFolderURLForROM:rom];
    NSURL *currentURL = [self URL];

    NSString *desiredName = [NSURL validFilenameFromString:[self displayName]];
    NSString *desiredFileName = [NSString stringWithFormat:@"%@.%@", desiredName, OESaveStateSuffix];
    NSURL    *url         = [saveStateDirectoryURL URLByAppendingPathComponent:desiredFileName isDirectory:NO];

    // check if save state is already where it's supposed to be
    if([[[url absoluteURL] standardizedURL] isEqualTo:[[currentURL absoluteURL] standardizedURL]]) return YES;

    // check if url is already take, determine unique url if so
    if([url checkResourceIsReachableAndReturnError:nil])
    {
        NSUInteger count = 1;
        do {
            desiredFileName = [NSString stringWithFormat:@"%@ %ld.%@", desiredName, count, OESaveStateSuffix];
            url = [saveStateDirectoryURL URLByAppendingPathComponent:desiredFileName isDirectory:NO];
            count ++;
        } while([[url standardizedURL] isNotEqualTo:[currentURL standardizedURL]] && [url checkResourceIsReachableAndReturnError:nil]);
    }

    // only proceed if the location has changed
    if([[[url absoluteURL] standardizedURL] isEqualTo:[[currentURL absoluteURL] standardizedURL]]) return YES;

    NSError *error = nil;
    if(![[NSFileManager defaultManager] moveItemAtURL:currentURL toURL:url error:&error])
    {
        DLog(@"Could not move save state to new location!");
        return NO;
    }

    [self setURL:url];
    [self save];

    return YES;
}


- (void)willSave
{
    if([self hasChanges] && ![self isDeleted])
        [self writeToDisk];
}

#pragma mark - Data Accessors
- (NSString *)displayName
{
    if(![self isSpecialState])
        return [self name];
    
    NSString *name = [self name];
    if([name isEqualToString:OESaveStateAutosaveName])
    {
        return OELocalizedString(@"Auto Save State", @"Autosave state display name");
    }
    else if([name isEqualToString:OESaveStateQuicksaveName])
    {
        return OELocalizedString(@"Quick Save State", @"Quicksave state display name");
    }
    else if([name rangeOfString:OESaveStateQuicksaveName].location == 0)
    {
        return [NSString stringWithFormat:OELocalizedString(@"Quick Save, Slot %@", @"Quicksave state display name with slot"), [name substringFromIndex:[OESaveStateQuicksaveName length]]];
    }
    return name;
}

- (BOOL)isSpecialState
{
    return [[self name] rangeOfString:OESaveStateSpecialNamePrefix].location == 0;
}

#pragma mark - Data Model Properties
@dynamic name, userDescription, timestamp;
@dynamic coreIdentifier, location, coreVersion;

- (NSURL *)URL
{
    NSURL *saveStateDirectoryURL = [[self libraryDatabase] stateFolderURL];
    return [NSURL URLWithString:[self location] relativeToURL:saveStateDirectoryURL];
}

- (void)setURL:(NSURL *)url
{
    NSURL *saveStateDirectoryURL = [[self libraryDatabase] stateFolderURL];
    NSString *string = [[url urlRelativeToURL:saveStateDirectoryURL] relativeString];

    // make sure we don't save trailing '/' for save state bundles
    string = [[self class] OE_stringByRemovingTrailingSlash:string];

    [self setLocation:string];
}

- (NSURL *)screenshotURL
{
    return [[self class] OE_screenShotURLWithBundleURL:[self URL]];
}

- (NSURL *)dataFileURL
{
    return [[self class] OE_dataURLWithBundleURL:[self URL]];
}

- (NSURL *)infoPlistURL
{
    return [[self class] OE_infoPlistURLWithBundleURL:[self URL]];
}

- (NSString *)systemIdentifier
{
    return [[[[self rom] game] system] systemIdentifier];
}

#pragma mark - Data Model Relationships

@dynamic rom;

@end
