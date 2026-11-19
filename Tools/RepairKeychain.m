#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <dlfcn.h>
#import <pwd.h>
#import <readpassphrase.h>
#import <sys/resource.h>
#import <unistd.h>

typedef OSStatus (*SetAccessWithPassword)(SecKeychainItemRef, SecAccessRef, UInt32, const void *);
typedef OSStatus (*ValidateTrustedApp)(SecTrustedApplicationRef, const char *);
typedef NS_ENUM(NSUInteger, RepairState) { RepairUnsupported, RepairAuthorized, RepairNeeded };

static NSString *hexString(NSData *data) {
    NSMutableString *text = [NSMutableString stringWithCapacity:data.length * 2];
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) [text appendFormat:@"%02x", bytes[i]];
    return text;
}

static NSDictionary *decodePartition(NSString *text) {
    if (text.length == 0 || text.length % 2) return nil;
    NSMutableData *data = [NSMutableData dataWithCapacity:text.length / 2];
    for (NSUInteger i = 0; i < text.length; i += 2) {
        NSString *pair = [text substringWithRange:NSMakeRange(i, 2)];
        NSScanner *scanner = [NSScanner scannerWithString:pair];
        scanner.charactersToBeSkipped = nil;
        unsigned value;
        if (![scanner scanHexInt:&value] || !scanner.isAtEnd || value > UINT8_MAX) return nil;
        uint8_t byte = value;
        [data appendBytes:&byte length:1];
    }
    id plist = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
    return [plist isKindOfClass:NSDictionary.class] ? plist : nil;
}

static NSString *signedPartition(NSString *path, NSString *fingerprint, NSString *identifier) {
    if (fingerprint.length != 40 ||
        [fingerprint rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet]].location != NSNotFound) {
        return nil;
    }
    NSString *expression = [NSString stringWithFormat:@"identifier \"%@\" and certificate leaf = H\"%@\"",
                            identifier, fingerprint];
    SecRequirementRef requirement = NULL;
    if (SecRequirementCreateWithString((__bridge CFStringRef)expression, kSecCSDefaultFlags, &requirement)) return nil;
    SecStaticCodeRef code = NULL;
    NSURL *url = [NSURL fileURLWithPath:path];
    OSStatus status = SecStaticCodeCreateWithPath((__bridge CFURLRef)url, kSecCSDefaultFlags, &code);
    if (!status) status = SecStaticCodeCheckValidity(code, kSecCSStrictValidate, requirement);
    CFRelease(requirement);
    CFDictionaryRef signingInfo = NULL;
    if (!status) status = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &signingInfo);
    if (code) CFRelease(code);
    if (status) return nil;
    NSDictionary *info = CFBridgingRelease(signingInfo);
    NSData *cdHash = info[(__bridge NSString *)kSecCodeInfoUnique];
    return cdHash.length == 20 ? [@"cdhash:" stringByAppendingString:hexString(cdHash)] : nil;
}

static NSArray *itemsForService(SecKeychainRef keychain, NSString *service, OSStatus *status) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: service,
        (__bridge id)kSecMatchSearchList: @[(__bridge id)keychain],
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
        (__bridge id)kSecReturnAttributes: @YES,
        (__bridge id)kSecReturnRef: @YES
    };
    CFTypeRef result = NULL;
    *status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (*status == errSecItemNotFound) {
        *status = errSecSuccess;
        return @[];
    }
    if (*status) return nil;
    return CFBridgingRelease(result);
}

static NSArray *matchingItems(SecKeychainRef keychain, OSStatus *status) {
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *service in @[@"local.passwordreminder.entries.v1",
                                @"local.passwordreminder.addresses.v1",
                                @"local.passwordreminder.cards.v1",
                                @"local.passwordreminder.category-settings.v1"]) {
        NSArray *matches = itemsForService(keychain, service, status);
        if (*status) return nil;
        [items addObjectsFromArray:matches];
    }
    return items;
}

static BOOL trustsApp(SecAccessRef access, const char *app, ValidateTrustedApp validate) {
    NSArray *rules = CFBridgingRelease(SecAccessCopyMatchingACLList(access, kSecACLAuthorizationDecrypt));
    for (id rule in rules) {
        CFArrayRef apps = NULL;
        CFStringRef description = NULL;
        SecKeychainPromptSelector flags = 0;
        OSStatus status = SecACLCopyContents((__bridge SecACLRef)rule, &apps, &description, &flags);
        NSArray *trusted = CFBridgingRelease(apps);
        if (description) CFRelease(description);
        if (status || (flags & CSSM_ACL_KEYCHAIN_PROMPT_REQUIRE_PASSPHRASE)) continue;
        for (id candidate in trusted) {
            if (validate((__bridge SecTrustedApplicationRef)candidate, app) == errSecSuccess) return YES;
        }
    }
    return NO;
}

static SecACLRef partitionRule(NSArray *rules) {
    SecACLRef result = NULL;
    for (id rule in rules) {
        SecACLRef acl = (__bridge SecACLRef)rule;
        CSSM_ACL_AUTHORIZATION_TAG tags[64];
        uint32 count = 64;
        if (SecACLGetAuthorizations(acl, tags, &count)) return NULL;
        for (uint32 i = 0; i < count; i++) {
            if (tags[i] != CSSM_ACL_AUTHORIZATION_PARTITION_ID) continue;
            if (result || count != 1) return NULL;
            result = acl;
        }
    }
    return result;
}

// Only the version-specific partition is appended. The existing app list and
// every existing partition stay in effect.
static RepairState planRepair(SecAccessRef access, const char *app, ValidateTrustedApp validate,
                              NSString *target, BOOL applyToAccess) {
    if (!trustsApp(access, app, validate)) return RepairUnsupported;
    CFArrayRef rules = NULL;
    if (SecAccessCopyACLList(access, &rules)) return RepairUnsupported;
    NSArray *entries = CFBridgingRelease(rules);
    SecACLRef rule = partitionRule(entries);
    if (!rule) return RepairUnsupported;
    CFArrayRef apps = NULL;
    CFStringRef encoded = NULL;
    CSSM_ACL_KEYCHAIN_PROMPT_SELECTOR prompt = {0};
    OSStatus status = SecACLCopySimpleContents(rule, &apps, &encoded, &prompt);
    NSArray *applications = CFBridgingRelease(apps);
    NSString *contents = CFBridgingRelease(encoded);
    if (status) return RepairUnsupported;
    NSMutableDictionary *payload = [decodePartition(contents) mutableCopy];
    id partitions = payload[@"Partitions"];
    if (![partitions isKindOfClass:NSArray.class] || [partitions count] == 0) return RepairUnsupported;
    for (id entry in partitions) if (![entry isKindOfClass:NSString.class]) return RepairUnsupported;
    if ([partitions containsObject:target]) return RepairAuthorized;
    if (!applyToAccess) return RepairNeeded;
    payload[@"Partitions"] = [partitions arrayByAddingObject:target];
    NSData *xml = [NSPropertyListSerialization dataWithPropertyList:payload format:NSPropertyListXMLFormat_v1_0
                                                           options:0 error:NULL];
    if (!xml) return RepairUnsupported;
    NSString *replacement = hexString(xml);
    status = SecACLSetSimpleContents(rule, (__bridge CFArrayRef)applications, (__bridge CFStringRef)replacement, &prompt);
    return status ? RepairUnsupported : RepairNeeded;
}

static int updateItems(NSArray *items, const char *app, NSString *partition, ValidateTrustedApp validate,
                       SetAccessWithPassword update, const char *password) {
    NSUInteger counts[3] = {0};
    for (NSDictionary *row in items) {
        NSString *account = row[(__bridge id)kSecAttrAccount];
        id reference = row[(__bridge id)kSecValueRef];
        if (![account isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:account] ||
            !reference || CFGetTypeID((__bridge CFTypeRef)reference) != SecKeychainItemGetTypeID()) {
            counts[RepairUnsupported]++;
            continue;
        }
        SecKeychainItemRef item = (__bridge SecKeychainItemRef)reference;
        SecAccessRef access = NULL;
        OSStatus status = SecKeychainItemCopyAccess(item, &access);
        if (status) { counts[RepairUnsupported]++; continue; }
        RepairState state = planRepair(access, app, validate, partition, password != NULL);
        if (state == RepairNeeded && password) {
            status = update(item, access, (UInt32)strlen(password), password);
        }
        CFRelease(access);
        if (status) {
            fprintf(stderr, "Repair stopped (macOS error %d). Updated %lu. You can run the tool again.\n",
                    (int)status, counts[RepairNeeded]);
            return -1;
        }
        counts[state]++;
    }
    if (password) {
        printf("Granted access to %lu items. Already authorized for %lu.\n", counts[RepairNeeded], counts[RepairAuthorized]);
    } else {
        printf("Already authorized for %lu items. Pending repair for %lu.\n", counts[RepairAuthorized], counts[RepairNeeded]);
    }
    if (counts[RepairUnsupported]) {
        printf("Skipped %lu items with different access rules.\n", counts[RepairUnsupported]);
    }
    if (!password && counts[RepairNeeded]) return (int)counts[RepairNeeded];
    return counts[RepairUnsupported] ? -1 : 0;
}

static int repair(SecKeychainRef keychain, NSString *app, NSString *partition,
                  ValidateTrustedApp validate, SetAccessWithPassword update, BOOL checkOnly) {
    OSStatus status = errSecSuccess;
    SecKeychainStatus keychainStatus = 0;
    status = SecKeychainGetStatus(keychain, &keychainStatus);
    if (status) {
        fprintf(stderr, "Could not check the Keychain status (%d).\n", (int)status);
        return 1;
    }
    NSArray *items = nil;
    if (keychainStatus & kSecUnlockStateStatus) {
        items = matchingItems(keychain, &status);
        if (!status) {
            int pending = updateItems(items, app.fileSystemRepresentation, partition, validate, update, NULL);
            if (checkOnly) return pending != 0;
            if (pending <= 0) return pending != 0;
        }
    }
    if (checkOnly) {
        fputs("Unlock the local login Keychain, then run the check again.\n", stderr);
        return 1;
    }

    char password[1024] = {0};
    int result = 1;
    if (!readpassphrase("Enter the local login Keychain password (input is hidden): ",
                        password, sizeof(password), RPP_REQUIRE_TTY)) {
        fputs("Canceled. Access settings are unchanged.\n", stderr);
    } else {
        status = SecKeychainUnlock(keychain, (UInt32)strlen(password), password, true);
        if (!status) items = matchingItems(keychain, &status);
        if (status) {
            fprintf(stderr, "Could not unlock or read the Keychain (%d). Access settings are unchanged.\n", (int)status);
        } else {
            result = updateItems(items, app.fileSystemRepresentation, partition, validate, update, password) != 0;
        }
    }
    volatile char *bytes = password;
    for (size_t i = 0; i < sizeof(password); i++) bytes[i] = 0;
    return result;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (getuid() == 0 || getuid() != geteuid()) return 64;
        struct rlimit noCoreDumps = {0, 0};
        if (setrlimit(RLIMIT_CORE, &noCoreDumps)) return 1;
#ifdef KEYCHAIN_REPAIR_TEST
        if (argc != 4 || !strstr(argv[3], "/Library/Keychains/PasswordReminder-fixture-")) return 64;
        BOOL checkOnly = NO;
        const char *keychainPath = argv[3];
        NSString *identifier = @"local.passwordreminder.partition-fixture";
#else
        BOOL checkOnly = argc == 4 && strcmp(argv[3], "--check") == 0;
        if (argc != 3 && !checkOnly) return 64;
        struct passwd *owner = getpwuid(getuid());
        if (!owner || !owner->pw_dir) return 1;
        NSString *path = [@(owner->pw_dir) stringByAppendingPathComponent:@"Library/Keychains/login.keychain-db"];
        const char *keychainPath = path.fileSystemRepresentation;
        NSString *identifier = @"local.passwordreminder.app";
#endif
        NSString *app = @(argv[1]);
        NSString *partition = signedPartition(app, @(argv[2]), identifier);
        if (!partition) {
            fputs("Could not verify the updated app's signature. Access settings are unchanged.\n", stderr);
            return 1;
        }

        SetAccessWithPassword update = (SetAccessWithPassword)dlsym(RTLD_DEFAULT, "SecKeychainItemSetAccessWithPassword");
        ValidateTrustedApp validate = (ValidateTrustedApp)dlsym(RTLD_DEFAULT, "SecTrustedApplicationValidateWithPath");
        if (!update || !validate || SecKeychainSetUserInteractionAllowed(false)) {
            fputs("Batch repair is unavailable on this version of macOS. Access settings are unchanged.\n", stderr);
            return 1;
        }
        SecKeychainRef keychain = NULL;
        OSStatus status = SecKeychainOpen(keychainPath, &keychain);
        if (status) {
            fprintf(stderr, "Could not open the local login Keychain (%d).\n", (int)status);
            return 1;
        }
        int result = repair(keychain, app, partition, validate, update, checkOnly);
        CFRelease(keychain);
        return result;
    }
}
