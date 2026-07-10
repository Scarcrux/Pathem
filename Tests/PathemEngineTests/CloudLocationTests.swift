import Foundation
import Testing

@testable import PathemEngine

@Suite struct CloudLocationTests {
    let home = "/Users/me"

    @Test func iCloudDriveRootAndTopLevelFolders() {
        let root = "\(home)/Library/Mobile Documents/com~apple~CloudDocs"
        #expect(CloudLocation.service(forFolderAt: root, home: home) == .iCloud)
        #expect(CloudLocation.service(forFolderAt: "\(root)/Documents", home: home) == .iCloud)
        #expect(CloudLocation.service(forFolderAt: "\(root)/Desktop", home: home) == .iCloud)
        // Any folder inside iCloud is marked, at any depth (consistent, not just the top level).
        #expect(CloudLocation.service(forFolderAt: "\(root)/Documents/Work", home: home) == .iCloud)
    }

    @Test func cloudStorageProviders() {
        let base = "\(home)/Library/CloudStorage"
        #expect(CloudLocation.service(forFolderAt: "\(base)/Dropbox", home: home) == .dropbox)
        #expect(
            CloudLocation.service(forFolderAt: "\(base)/GoogleDrive-me@gmail.com", home: home)
                == .googleDrive)
        #expect(CloudLocation.service(forFolderAt: "\(base)/OneDrive-Personal", home: home) == .oneDrive)
        #expect(CloudLocation.service(forFolderAt: "\(base)/Box-Box", home: home) == .box)
        // Some Macs surface iCloud under CloudStorage too, as "iCloudDrive-...".
        #expect(
            CloudLocation.service(forFolderAt: "\(base)/iCloudDrive-iCloudDrive (5-13-25)", home: home)
                == .iCloud)
        #expect(CloudLocation.service(forFolderAt: "\(base)/SomethingElse-x", home: home) == .generic)
    }

    @Test func cloudStorageFoldersBadgedAtAnyDepth() {
        let drive = "\(home)/Library/CloudStorage/GoogleDrive-me@gmail.com"
        #expect(CloudLocation.service(forFolderAt: "\(drive)/Projects", home: home) == .googleDrive)
        #expect(CloudLocation.service(forFolderAt: "\(drive)/Projects/Sub", home: home) == .googleDrive)
    }

    @Test func cloudStorageContainerItselfIsNotAService() {
        #expect(CloudLocation.service(forFolderAt: "\(home)/Library/CloudStorage", home: home) == nil)
    }

    @Test func legacyHomeSyncFolders() {
        #expect(CloudLocation.service(forFolderAt: "\(home)/Dropbox", home: home) == .dropbox)
        #expect(CloudLocation.service(forFolderAt: "\(home)/Dropbox/Photos", home: home) == .dropbox)
        #expect(CloudLocation.service(forFolderAt: "\(home)/Google Drive", home: home) == .googleDrive)
    }

    @Test func nonCloudPathsReturnNil() {
        #expect(CloudLocation.service(forFolderAt: "\(home)/Documents", home: home) == nil)
        #expect(CloudLocation.service(forFolderAt: "\(home)/Code/pathem", home: home) == nil)
        #expect(CloudLocation.service(forFolderAt: "/tmp", home: home) == nil)
    }

    @Test func trailingSlashesTolerated() {
        let root = "\(home)/Library/Mobile Documents/com~apple~CloudDocs/"
        #expect(CloudLocation.service(forFolderAt: root, home: home) == .iCloud)
        #expect(CloudLocation.service(forFolderAt: "\(home)/Dropbox/", home: "\(home)/") == .dropbox)
    }

    @Test func everyServiceHasSymbolAndTint() {
        for service in CloudService.allCases {
            #expect(!service.symbolName.isEmpty)
            #expect(service.tintHex.hasPrefix("#"))
            #expect(!service.displayName.isEmpty)
        }
    }
}
