// ----------------------------------------------------------------------------
//
//  DatabaseHelper.swift
//
//  @author     Alexander Bragin <alexander.bragin@gmail.com>
//  @copyright  Copyright (c) 2015, MediariuM Ltd. All rights reserved.
//  @link       http://www.mediarium.com/
//
// ----------------------------------------------------------------------------

// A helper class to manage database creation and version management.
// @link https://github.com/android/platform_frameworks_base/blob/master/core/java/android/database/sqlite/SQLiteOpenHelper.java

// MARK: - Types
public typealias Database = Connection

public class DatabaseHelper
{
// MARK: - Construction
    public init(databaseName: String?, version: Int, readonly: Bool = false, delegate: DatabaseOpenDelegate? = nil)
    {
        // Init instance variables
        self.database = openOrCreateDatabase(databaseName, version: version, readonly: readonly, delegate: delegate)
    }

    private init() {
        // Do nothing ..
    }

    deinit {
        // Release resources
        self.database = nil
    }

// MARK: - Properties

    public final private(set) var database: Database?
    
    public var userVersion: Int {
        get {
            let version = database?.scalar("PRAGMA user_version") ?? Int64(0)
            return Int(version as! Int64)
        }
        set
        {
            do {
                try database?.run("PRAGMA user_version = \(transcode(Int64(newValue)))")
            } catch {
                MDLog.e("Can't set db userVersion: \(error)")
            }
        }
    }

// MARK: - Functions

    /// Checks if database file exists and integrity check of the entire database was successful.
    public static func isValidDatabase(databaseName: String?, delegate: DatabaseOpenDelegate? = nil) -> Bool {
        return DatabaseHelper.sharedInstance.validateDatabase(databaseName, delegate: delegate)
    }

// MARK: - Internal Functions
    
    func unpackDatabaseTemplate(databaseName: String, assetPath: NSURL) -> NSURL?
    {
        var pathUrl: NSURL?

        // Copy template file from application assets to the temporary directory
        if let tmpPathUrl = makeTemplatePath(databaseName)
        {
            // Remove previous template file
            mdc_removeItemAtURL(tmpPathUrl)

            // Copy new template file
            if mdc_copyItemAtURL(assetPath, toURL: tmpPathUrl) {
                pathUrl = tmpPathUrl
            }
        }
        else {
            mdc_fatalError("Could not make temporary path for database ‘\(databaseName)’.")
        }

        return pathUrl
    }

    func makeDatabasePath(databaseName: String?) -> NSURL?
    {
        let name = sanitizeName(databaseName)
        var path: NSURL?

        // Build path to the database file
        if !name.isEmpty && (name != Inner.InMemoryDatabase) {
            path = NSFileManager.databasesDirectory?.URLByAppendingPathComponent((name.mdc_md5String as NSString).stringByAppendingPathExtension(FileExtension.SQLite)!)
        }

        // Done
        return path
    }

    func makeTemplatePath(databaseName: String?) -> NSURL?
    {
        let name = sanitizeName(databaseName)
        var path: NSURL?

        // Build path to the template file
        if !name.isEmpty && (name != Inner.InMemoryDatabase) {
            path = NSFileManager.temporaryDirectory?.URLByAppendingPathComponent((name.mdc_md5String as NSString).stringByAppendingPathExtension(FileExtension.SQLite)!)
        }

        // Done
        return path
    }

// MARK: - Private Functions

    private func validateDatabase(databaseName: String?, delegate: DatabaseOpenDelegate? = nil) -> Bool
    {
        var result = false

        // Check if database file exists
        if let path = makeDatabasePath(databaseName) where path.mdc_isFileExists
        {
            // Check integrity of database
            let database = openDatabase(databaseName, version: nil, readonly: true, delegate: delegate)
            result = checkDatabaseIntegrity(database)
        }

        // Done
        return result
    }

    private func openOrCreateDatabase(databaseName: String?, version: Int, readonly: Bool, delegate: DatabaseOpenDelegate?) -> Database?
    {
        // Try to open existing database
        var database = openDatabase(databaseName, version: version, readonly: readonly, delegate: delegate)

        // Create and open new database
        if (database == nil) {
            database = createDatabase(databaseName, version: version, readonly: readonly, delegate: delegate)
        }

        // Done
        return database
    }

    private func openDatabase(databaseName: String?, version: Int?, readonly: Bool, delegate: DatabaseOpenDelegate?) -> Database?
    {
        var name: String! = sanitizeName(databaseName)
        var database: Database!

        // Validate database name
        if let path = makeDatabasePath(databaseName) where path.mdc_isFileExists {
            name = path.path
        }
        else if (name != Inner.InMemoryDatabase) {
            name = nil
        }

        // Open on-disk OR in-memory database
        if str_isNotEmpty(name) {
            database = createDatabaseObject(name, readonly: readonly)

            // Send events to the delegate
            if let delegate = delegate where (database.handle != nil)
            {
                Try {
                    // Configure the open database
                    delegate.configureDatabase(databaseName, database: database)

                    // Check database connection
                    if !database.goodConnection {
                        NSException(name: NSError.DatabaseError.Domain, reason: "Database connection is invalid.", userInfo: nil).raise()
                    }

                    // Migrate database
                    if  let newVersion = version {
                        let oldVersion = self.userVersion

                        // Init OR update database if needed
                        if (oldVersion != newVersion)
                        {
                            if database.readonly {
                                NSException(name: NSError.DatabaseError.Domain, reason: "Can't migrate read-only database from version \(oldVersion) to \(newVersion).", userInfo: nil).raise()
                            }

                            var blockException: NSException?
                            self.runTransaction(database, mode: .Exclusive, block: { statement in
                                var result: TransactionResult!
                                var exception: NSException?
                                
                                Try {
                                    
                                    if (oldVersion == 0) {
                                        delegate.databaseDidCreate(databaseName, database: database)
                                    }
                                    else
                                    {
                                        if (oldVersion > newVersion) {
                                            delegate.downgradeDatabase(databaseName, database: database, oldVersion: oldVersion, newVersion: newVersion)
                                        }
                                        else {
                                            delegate.upgradeDatabase(databaseName, database: database, oldVersion: oldVersion, newVersion: newVersion)
                                        }
                                    }
                                    
                                    // Update schema version
                                    self.userVersion = newVersion
                                    
                                    // Commit transaction on success
                                    result = .Commit
                                    
                                    }.Catch { e in
                                        // Rollback transaction on error
                                        exception = e
                                        result = .Rollback
                                }
                                
                                // NOTE: Bug fix for block variable
                                blockException = exception
                                
                                if result == TransactionResult.Rollback {
                                    throw DatabaseError.FailedTransaction
                                }
                            })

                            // Re-throw exception if exists
                            blockException?.raise()
                        }
                    }

                    // Database did open sucessfully
                    delegate.databaseDidOpen(databaseName, database: database)

                }.Catch { e in

                    // Convert NSException to NSError
                    let error = NSError(code: NSError.DatabaseError.Code.DatabaseIsInvalid, description: e.reason)

                    // Could not open OR migrate database
                    delegate.databaseDidOpenWithError(databaseName, error: error)
                    database = nil
                }
            }
            // Check database connection
            else if !database.goodConnection {
                database = nil
            }

        }

        // Done
        return database
    }
    
    private func createDatabase(databaseName: String?, version: Int, readonly: Bool, delegate: DatabaseOpenDelegate?) -> Database?
    {
        let name = sanitizeName(databaseName)
        var database: Database?

        // Create on-disk database
        if let dstPath = makeDatabasePath(databaseName)
        {
            // Remove previous database file
            mdc_removeItemAtURL(dstPath)

            // Get path of the database template file from delegate
            if let (path, encryptionKey) = delegate?.databaseWillCreate(databaseName) where (path != nil) && path!.mdc_isFileExists
            {
                // Unpack database template from the assets
                if let tmpPath = unpackDatabaseTemplate(databaseName!, assetPath: path!) where tmpPath.mdc_isFileExists,
                   let uriPath = tmpPath.path
                {
                    var db: Database? = createDatabaseObject(uriPath, readonly: false)
                    
                    if checkDatabaseIntegrity(db)
                    {
                        // Export/copy database template to the "Databases" folder
                        if let key = encryptionKey where !key.isEmpty
                        {
                            // FMDB with SQLCipher Tutorial
                            // @link http://www.guilmo.com/fmdb-with-sqlcipher-tutorial/

                            execute(db, query: "ATTACH DATABASE '\(dstPath.path!)' AS `encrypted` KEY '\(key.mdc_hexString)';")
                            execute(db, query: "SELECT sqlcipher_export('encrypted');")
                            execute(db, query: "DETACH DATABASE `encrypted`;")
                        }
                        else {
                            mdc_copyItemAtURL(tmpPath, toURL: dstPath)
                        }

                        // Exclude file from back-up to iCloud
                        NSFileManager.excludedPathFromBackup(dstPath)
                    }

                    // Release resources
                    db = nil

                    // Remove database template file
                    mdc_removeItemAtURL(tmpPath)
                }
            }

            // Try to open created database
            database = openDatabase(databaseName, version: version, readonly: readonly, delegate: delegate)

            // Remove corrupted database file
            if (database == nil) {
                mdc_removeItemAtURL(dstPath)
            }
        }
        // Create in-memory database
        else if (name == Inner.InMemoryDatabase) {
            database = openDatabase(databaseName, version: version, readonly: readonly, delegate: delegate)
        }

        // Done
        return database
    }

    private func checkDatabaseIntegrity(database: Database?) -> Bool
    {
        var result = false

        // Check integrity of database
        if (database?.handle != nil) {
            if let value = database?.scalar("PRAGMA quick_check;") as? String {
                result = value.caseInsensitiveCompare("ok") == .OrderedSame
            }
        }

        // Done
        return result
    }

    private func sanitizeName(name: String?) -> String {
        return str_isNotEmpty(name?.trimmed()) ? name! : Inner.InMemoryDatabase
    }
    
    private func execute(database: Database?, query: String?)
    {
        guard let database = database,
              let query = query else {
                return
        }
        
        do {
            try database.execute(query)
        } catch {
            mdc_assertFailure("Database query \(query) failed with error \(error)")
        }
    }
    
    private func createDatabaseObject(uriPath: String?, readonly: Bool) -> Database?
    {
        guard let uriPath = uriPath else {
            mdc_assertFailure("Can't create database object with nil uri path")
            return nil
        }
        
        do {
            return try Database(uriPath, readonly: false)
        } catch {
            mdc_assertFailure("Can't open db at \(uriPath) with readonly \(readonly): \(error)")
            return nil
        }
    }
    
    private func runTransaction(database: Database?, mode: Database.TransactionMode, block: () throws -> Void) {
        guard let database = database else {
            mdc_assertFailure("Can't run transaction on nil database")
            return
        }
        
        do {
            try database.transaction(mode, block: block)
        } catch {
            mdc_assertFailure("Transaction failed with error \(error)")
        }
    }

// MARK: - Constants

    private struct Inner {
        static let InMemoryDatabase = Database.Location.InMemory.description
    }

    private struct FileExtension {
        static let SQLite = "sqlite"
    }
    
// MARK: - Enums
    
    enum TransactionResult {
        case Rollback
        case Commit
    }
    
    enum DatabaseError : ErrorType {
        case FailedTransaction
    }

// MARK: - Variables

    private static let sharedInstance: DatabaseHelper = DatabaseHelper()

}

// ----------------------------------------------------------------------------
// MARK: - @interface NSURL
// ----------------------------------------------------------------------------

private extension NSURL
{
// MARK: - Functions

    var mdc_isFileExists: Bool {
        return self.fileURL && self.checkResourceIsReachableAndReturnError(nil)
    }

}

// ----------------------------------------------------------------------------
