/* This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0. If a copy of the MPL was not distributed with this file, You can obtain one at http://mozilla.org/MPL/2.0/. */


import UIKit
import CoreData
import Foundation
import Shared

class Bookmark: NSManagedObject, WebsitePresentable, Syncable {
    
    @NSManaged var isFolder: Bool
    @NSManaged var title: String?
    @NSManaged var customTitle: String?
    @NSManaged var url: String?
    @NSManaged var visits: Int32
    @NSManaged var lastVisited: NSDate?
    @NSManaged var created: NSDate?
    @NSManaged var order: Int16
    @NSManaged var tags: [String]?
    
    /// Should not be set directly, due to specific formatting required, use `syncUUID` instead
    /// CD does not allow (easily) searching on transformable properties, could use binary, but would still require tranformtion
    //  syncUUID should never change
    @NSManaged var syncDisplayUUID: String?
    @NSManaged var syncParentDisplayUUID: String?
    @NSManaged var parentFolder: Bookmark?
    @NSManaged var children: Set<Bookmark>?
    
    @NSManaged var domain: Domain?

    // To trigger fetchedResultsController to update, change this value.
    // For instance, when a favicon is set on a domain, to notify any bookmarks or history items that
    // are displayed in a table and waiting for a favicon, you can change markDirty, and the favicon will update
    @NSManaged var markDirty: Int16
    
    var syncParentUUID: [Int]? {
        get { return SyncHelpers.syncUUID(fromString: syncParentDisplayUUID) }
        set(value) {
            // Save actual instance variable
            syncParentDisplayUUID = SyncHelpers.syncDisplay(fromUUID: value)

            // Attach parent, only works if parent exists.
            let parent = Bookmark.get(parentSyncUUID: value, context: self.managedObjectContext)
            parentFolder = parent
        }
    }
    
    var displayTitle: String? {
        if let custom = customTitle where !custom.isEmpty {
            return customTitle
        }
        
        if let t = title where !t.isEmpty {
            return title
        }
        
        // Want to return nil so less checking on frontend
        return nil
    }
    
    override func awakeFromInsert() {
        super.awakeFromInsert()
        created = NSDate()
        lastVisited = created
    }
    
    func asDictionary(deviceId deviceId: [Int]?, action: Int?) -> [String: AnyObject] {
        return SyncBookmark(record: self, deviceId: deviceId, action: action).dictionaryRepresentation()
    }

    static func entity(context:NSManagedObjectContext) -> NSEntityDescription {
        return NSEntityDescription.entityForName("Bookmark", inManagedObjectContext: context)!
    }

    class func frc(parentFolder parentFolder: Bookmark?) -> NSFetchedResultsController {
        let fetchRequest = NSFetchRequest()
        fetchRequest.entity = Bookmark.entity(DataController.moc)
        fetchRequest.fetchBatchSize = 20
        fetchRequest.fetchLimit = 200
        fetchRequest.sortDescriptors = [NSSortDescriptor(key:"order", ascending: true), NSSortDescriptor(key:"created", ascending: false)]
        if let parentFolder = parentFolder {
            fetchRequest.predicate = NSPredicate(format: "parentFolder == %@", parentFolder)
        } else {
            fetchRequest.predicate = NSPredicate(format: "parentFolder == nil")
        }

        return NSFetchedResultsController(fetchRequest: fetchRequest, managedObjectContext:DataController.moc, sectionNameKeyPath: nil, cacheName: nil)
    }
    
    // Syncable
    func update(syncRecord record: SyncRecord) {
        guard let bookmark = record as? SyncBookmark, let site = bookmark.site else { return }
        title = site.title
        customTitle = site.customTitle
        url = site.location
        lastVisited = NSDate(timeIntervalSince1970:(Double(site.lastAccessedTime ?? 0) / 1000.0))
        syncParentUUID = bookmark.parentFolderObjectId
        // No auto-save, must be handled by caller if desired
    }
    
    func update(customTitle customTitle: String?, url: String?, save: Bool = false) {
        
        // See if there has been any change
        if self.customTitle == customTitle && self.url == url {
            return
        }
        
        if let ct = customTitle where !ct.isEmpty {
            self.customTitle = customTitle
        }
        
        if let u = url where !u.isEmpty {
            self.url = url
        }
        
        if save {
            DataController.saveContext(self.managedObjectContext)
        }
        
        Sync.shared.sendSyncRecords(.bookmark, action: .update, records: [self])
    }

    static func add(rootObject root: SyncRecord?, save: Bool, sendToSync: Bool, context: NSManagedObjectContext) -> Syncable? {
        // Explicit parentFolder to force method decision
        return add(rootObject: root as? SyncBookmark, save: save, sendToSync: sendToSync, parentFolder: nil, context: context)
    }
    
    // Should not be used for updating, modify to increase protection
    class func add(rootObject root: SyncBookmark?, save: Bool = false, sendToSync: Bool = false, parentFolder: Bookmark? = nil, context: NSManagedObjectContext) -> Bookmark? {
        let bookmark = root
        let site = bookmark?.site
     
        var bk: Bookmark!
        if let id = root?.objectId, let foundbks = Bookmark.get(syncUUIDs: [id], context: context) as? [Bookmark], let foundBK = foundbks.first {
            // Found a pre-existing bookmark, cannot add duplicate
            // Turn into 'update' record instead
            bk = foundBK
        } else {
            bk = Bookmark(entity: Bookmark.entity(context), insertIntoManagedObjectContext: context)
        }
        
        // Should probably have visual indication before reaching this point
        if site?.location?.startsWith(WebServer.sharedInstance.base) ?? false {
            return nil
        }
        
        // Use new values, fallback to previous values
        bk.url = site?.location ?? bk.url
        bk.title = site?.title ?? bk.title
        bk.customTitle = site?.customTitle ?? bk.customTitle // TODO: Check against empty titles
        bk.isFolder = bookmark?.isFolder ?? bk.isFolder ?? false
        bk.syncUUID = root?.objectId ?? bk.syncUUID ?? Niceware.shared.uniqueSerialBytes(count: 16)
        bk.created = site?.creationNativeDate ?? NSDate()
        bk.lastVisited = site?.lastAccessedNativeDate ?? NSDate()
        
        if let location = site?.location, let url = NSURL(string: location) {
            bk.domain = Domain.getOrCreateForUrl(url, context: context)
        }
        
        // Must assign both, in cae parentFolder does not exist, need syncParentUUID to attach later
        bk.parentFolder = parentFolder
        bk.syncParentUUID = bookmark?.parentFolderObjectId ?? bk.syncParentUUID

        // For folders that are saved _with_ a syncUUID, there may be child bookmarks
        //  (e.g. sync sent down bookmark before parent folder)
        if bk.isFolder {
            // Find all children and attach them
            if let children = Bookmark.getChildren(forFolderUUID: bk.syncUUID, context: context) {
                
                // TODO: Setup via bk.children property instead
                children.forEach { $0.parentFolder = bk }
            }
        }
        
        if save {
            DataController.saveContext(context)
        }
        
        if sendToSync {
            // Submit to server
            Sync.shared.sendSyncRecords(.bookmark, action: .create, records: [bk])
        }
        
        return bk
    }
    
    // TODO: DELETE
    // Aways uses main context
    class func add(url url: NSURL?,
                       title: String?,
                       customTitle: String? = nil, // Folders only use customTitle
                       parentFolder:Bookmark? = nil,
                       isFolder:Bool = false) -> Bookmark? {
        
        let site = SyncSite()
        site.title = title
        site.customTitle = customTitle
        site.location = url?.absoluteString
        
        let bookmark = SyncBookmark()
        bookmark.isFolder = isFolder
        bookmark.parentFolderObjectId = parentFolder?.syncUUID
        bookmark.site = site
        
        return self.add(rootObject: bookmark, save: true, sendToSync: true, parentFolder: parentFolder, context: DataController.moc)
    }
    
    // TODO: Migration syncUUIDS still needs to be solved
    // Should only ever be used for migration from old db
    // Always uses worker context
    class func addForMigration(url url: String?, title: String, customTitle: String, parentFolder: Bookmark?, isFolder: Bool?) -> Bookmark? {
        
        let site = SyncSite()
        site.title = title
        site.customTitle = customTitle
        site.location = url
        
        let bookmark = SyncBookmark()
        bookmark.isFolder = isFolder
//        bookmark.parentFolderObjectId = [parentFolder]
        bookmark.site = site
        
        return self.add(rootObject: bookmark, save: true, context: DataController.shared.workerContext())
    }

    class func contains(url url: NSURL, completionOnMain completion: ((Bool)->Void)) {
        var found = false
        let context = DataController.shared.workerContext()
        context.performBlock {
            if let count = get(forUrl: url, countOnly: true, context: context) as? Int {
                found = count > 0
            }
            postAsyncToMain {
                completion(found)
            }
        }
    }

    class func frecencyQuery(context: NSManagedObjectContext, containing: String?) -> [Bookmark] {
        assert(!NSThread.isMainThread())

        let fetchRequest = NSFetchRequest()
        fetchRequest.fetchLimit = 5
        fetchRequest.entity = Bookmark.entity(context)
        
        var predicate = NSPredicate(format: "lastVisited > %@", History.ThisWeek)
        if let query = containing {
            predicate = NSPredicate(format: predicate.predicateFormat + " AND url CONTAINS %@", query)
        }
        fetchRequest.predicate = predicate

        do {
            if let results = try context.executeFetchRequest(fetchRequest) as? [Bookmark] {
                return results
            }
        } catch {
            let fetchError = error as NSError
            print(fetchError)
        }
        return [Bookmark]()
    }
}

// TODO: Document well
// Getters
extension Bookmark {
    private static func get(forUrl url: NSURL, countOnly: Bool = false, context: NSManagedObjectContext) -> AnyObject? {
        guard let str = url.absoluteString else { return nil }
        let fetchRequest = NSFetchRequest()
        fetchRequest.entity = Bookmark.entity(context)
        fetchRequest.predicate = NSPredicate(format: "url == %@", str)
        do {
            if countOnly {
                let count = try context.countForFetchRequest(fetchRequest)
                return count
            }
            let results = try context.executeFetchRequest(fetchRequest) as? [Bookmark]
            return results?.first
        } catch {
            let fetchError = error as NSError
            print(fetchError)
        }
        return nil
    }
    
    static func getChildren(forFolderUUID syncUUID: [Int]?, context: NSManagedObjectContext) -> [Bookmark]? {
        guard let searchableUUID = SyncHelpers.syncDisplay(fromUUID: syncUUID) else {
            return nil
        }
        
        return get(predicate: NSPredicate(format: "syncParentDisplayUUID == %@", searchableUUID), context: context)
    }
    
    static func get(parentSyncUUID parentUUID: [Int]?, context: NSManagedObjectContext?) -> Bookmark? {
        guard let searchableUUID = SyncHelpers.syncDisplay(fromUUID: parentUUID) else {
            return nil
        }
        
        return get(predicate: NSPredicate(format: "syncDisplayUUID == %@", searchableUUID), context: context)?.first
    }
    
    static func getFolders(bookmark: Bookmark?, context: NSManagedObjectContext) -> [Bookmark] {
    
        var predicate: NSPredicate?
        if let parent = bookmark?.parentFolder {
            predicate = NSPredicate(format: "isFolder == true and parentFolder == %@", parent)
        } else {
            predicate = NSPredicate(format: "isFolder == true and parentFolder.@count = 0")
        }
        
        return get(predicate: predicate, context: context) ?? [Bookmark]()
    }
    
    // TODO: Remove
    static func getAllBookmarks(context: NSManagedObjectContext) -> [Bookmark] {
        return get(predicate: nil, context: context) ?? [Bookmark]()
    }
}

// TODO: REMOVE!! This should be located in abstraction
extension Bookmark {
    class func remove(forUrl url: NSURL, save: Bool = true, context: NSManagedObjectContext) -> Bool {
        if let bm = get(forUrl: url, context: context) as? Bookmark {
            bm.remove(save: save)
            return true
        }
        return false
    }
}

