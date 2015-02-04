////////////////////////////////////////////////////////////////////////////
//
// Copyright 2014 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

import XCTest
import RealmSwift
import Realm
import Realm.Private

private func realmWithCustomSchema(path: String, schema :RLMSchema) -> RLMRealm {
    return RLMRealm(path: path, key: nil, readOnly: false, inMemory: false, dynamic: true, schema: schema, error: nil)!
}

private func realmWithSingleClass(path: String, objectSchema: RLMObjectSchema) -> RLMRealm {
    let schema = RLMSchema()
    schema.objectSchema = [objectSchema]
    return realmWithCustomSchema(path, schema)
}

private func realmWithSingleClassProperties(path: String, className: String, properties: [AnyObject]) -> RLMRealm {
    let objectSchema = RLMObjectSchema(className: className, objectClass: MigrationObject.self, properties: properties)
    return realmWithSingleClass(path, objectSchema)
}

class MigrationTests: TestCase {

    // MARK Utility methods

    // create realm at path and test version is 0
    private func createAndTestRealmAtPath(realmPath: String) {
        autoreleasepool { () -> () in
            Realm(path: realmPath)
            return
        }
        XCTAssertEqual(UInt(0), schemaVersionAtPath(realmPath)!, "Initial version should be 0")
    }

    // migrate realm at path and ensure migration
    private func migrateAndTestRealmAtPath(realmPath: String, shouldRun: Bool = true, schemaVersion: UInt = 1, autoMigration: Bool = false, block: MigrationBlock? = nil) {
        var didRun = false
        setSchemaVersion(schemaVersion, realmPath, { migration, oldSchemaVersion in
            if let block = block {
                block(migration: migration, oldSchemaVersion: oldSchemaVersion)
            }
            didRun = true
            return
        })

        if autoMigration {
            Realm(path: realmPath)
        }
        else {
            migrateRealm(realmPath, encryptionKey: nil)
        }

        XCTAssertEqual(didRun, shouldRun)
    }

    // migrate default realm and ensure migration
    private func migrateAndTestDefaultRealm(shouldRun: Bool = true, schemaVersion: UInt = 1, autoMigration: Bool = false, block: MigrationBlock? = nil) {
        var didRun = false
        setDefaultRealmSchemaVersion(schemaVersion, { migration, oldSchemaVersion in
            if let block = block {
                block(migration: migration, oldSchemaVersion: oldSchemaVersion)
            }
            didRun = true
            return
        })

        // accessing Realm should automigrate
        if autoMigration {
            defaultRealm()
        }
        else {
            migrateRealm(defaultRealmPath(), encryptionKey: nil)
        }
        XCTAssertEqual(didRun, shouldRun)
    }


    // MARK Test cases

    func testSetDefaultRealmSchemaVersion() {
        createAndTestRealmAtPath(defaultRealmPath())
        migrateAndTestDefaultRealm()

        XCTAssertEqual(UInt(1), schemaVersionAtPath(defaultRealmPath())!)
    }

    func testSetSchemaVersion() {
        createAndTestRealmAtPath(testRealmPath())
        migrateAndTestRealmAtPath(testRealmPath())

        XCTAssertEqual(UInt(1), schemaVersionAtPath(testRealmPath())!)
    }

    func testSchemaVersionAtPath() {
        var error : NSError? = nil
        XCTAssertNil(schemaVersionAtPath(defaultRealmPath(), error: &error), "Version should be nil before Realm creation")
        XCTAssertNotNil(error, "Error should be set")

        defaultRealm()
        XCTAssertEqual(UInt(0), schemaVersionAtPath(defaultRealmPath())!, "Initial version should be 0")
    }

    func testMigrateRealm() {
        createAndTestRealmAtPath(testRealmPath())

        // manually migrate (autoMigration == false)
        migrateAndTestRealmAtPath(testRealmPath(), shouldRun: true, autoMigration: false)

        // calling again should be no-op
        migrateAndTestRealmAtPath(testRealmPath(), shouldRun: false, autoMigration: false)

        // test auto-migration
        migrateAndTestRealmAtPath(testRealmPath(), schemaVersion: 2, shouldRun: true, autoMigration: true)
    }

    func testMigrationProperties() {
        let prop = RLMProperty(name: "stringCol", type: RLMPropertyType.Int, objectClassName: nil, indexed: false)
        autoreleasepool { () -> () in
            realmWithSingleClassProperties(defaultRealmPath(), "SwiftStringObject", [prop])
            return
        }

        migrateAndTestDefaultRealm(block: { migration, oldSchemaVersion in
            XCTAssertEqual(migration.oldSchema.objectSchema.count, 1)
            XCTAssertGreaterThan(migration.newSchema.objectSchema.count, 1)
            XCTAssertEqual(migration.oldSchema.objectSchema[0].properties.count, 1)
            XCTAssertEqual(migration.newSchema["SwiftStringObject"]!.properties.count, 1)
            XCTAssertEqual(migration.oldSchema["SwiftStringObject"]!.properties[0].type, PropertyType.Int)
            XCTAssertEqual(migration.newSchema["SwiftStringObject"]!["stringCol"]!.type, PropertyType.String)
        })
    }

    func testEnumerate() {
        self.migrateAndTestDefaultRealm(block: { migration, oldSchemaVersion in
            migration.enumerate("SwiftStringObject", { oldObj, newObj in
                XCTFail("No objects to enumerate")
            })
        })

        // add object
        defaultRealm().write({
            SwiftStringObject.createInRealm(defaultRealm(), withObject: ["string"])
            return
        })

        migrateAndTestDefaultRealm(schemaVersion: 2, block: { migration, oldSchemaVersion in
            var count = 0
            migration.enumerate("SwiftStringObject", { oldObj, newObj in
                XCTAssertEqual(newObj.objectSchema.className, "SwiftStringObject")
                XCTAssertEqual(oldObj.objectSchema.className, "SwiftStringObject")
                XCTAssertEqual(newObj["stringCol"] as String, "string")
                XCTAssertEqual(oldObj["stringCol"] as String, "string")
                count++
            })
            XCTAssertEqual(count, 1)
        })
    }

    func testCreate() {
        migrateAndTestDefaultRealm(block: { migration, oldSchemaVersion in
            migration.create("SwiftStringObject", withObject:["string"])
            migration.create("SwiftStringObject", withObject:["stringCol": "string"])

            var count = 0
            migration.enumerate("SwiftStringObject", { oldObj, newObj in
                XCTAssertEqual(newObj["stringCol"] as String, "string")
                XCTAssertNil(oldObj["stringCol"], "Objects created during migration have nil oldObj")
                count++
            })
            XCTAssertEqual(count, 2)
        })

        XCTAssertEqual(objects(SwiftStringObject.self).count, 2)
    }

    func testDelete() {
        autoreleasepool { () -> () in
            defaultRealm().write({
                SwiftStringObject.createInRealm(defaultRealm(), withObject: ["string1"])
                SwiftStringObject.createInRealm(defaultRealm(), withObject: ["string2"])
                return
            })

            self.migrateAndTestDefaultRealm(block: { migration, oldSchemaVersion in
                var deleted = false;
                migration.enumerate("SwiftStringObject", { oldObj, newObj in
                    if deleted == false {
                        migration.delete(newObj)
                        deleted = true
                    }
                })
            })
        }

        XCTAssertEqual(objects(SwiftStringObject.self).count, 1)
    }
}

