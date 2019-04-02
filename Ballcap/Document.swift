//
//  Document.swift
//  Ballcap
//
//  Created by 1amageek on 2019/03/27.
//  Copyright © 2019 Stamp Inc. All rights reserved.
//

import FirebaseFirestore
import FirebaseStorage

public protocol Modelable: Referencable {
    init()
    static var isIncludedInTimestamp: Bool { get }
}

public extension Modelable {

    static var isIncludedInTimestamp: Bool {
        return true
    }

    static var modelVersion: String {
        return "1"
    }

    static var modelName: String {
        return String(describing: Mirror(reflecting: self).subjectType).components(separatedBy: ".").first!.lowercased()
    }

    static var path: String {
        return "version/\(self.modelVersion)/\(self.modelName)"
    }

    static var collectionReference: CollectionReference {
        return Firestore.firestore().collection(self.path)
    }
}

public protocol Documentable {
    associatedtype Model

    var id: String { get }

    var path: String { get }
}

public enum DocumentError: Error {
    case invalidReference
    case invalidData
    case timeout

    public var description: String {
        switch self {
        case .invalidReference: return "The value you are trying to reference is invalid."
        case .invalidData: return "Invalid data."
        case .timeout: return "DataSource fetch timed out."
        }
    }
}

public class Document<Model: Codable & Modelable>: NSObject, Documentable {

    public typealias Model = Model

    public enum CachePolicy {
        case `default`          // cache then network
        case cacheOnly
        case networkOnly
    }

    public var isIncludedInTimestamp: Bool {
        return Model.isIncludedInTimestamp
    }

    public var id: String {
        return self.documentReference.documentID
    }

    public var path: String {
        return self.documentReference.path
    }

    private(set) var snapshot: DocumentSnapshot?

    private(set) var documentReference: DocumentReference!

    var storageReference: StorageReference {
        return Storage.storage().reference().child(self.path)
    }

    var data: Model?

    override init() {
        self.data = Model()
        super.init()
        self.documentReference = Model.collectionReference.document()
    }

    init(id: String) {
        self.data = Model()
        super.init()
        self.documentReference = Model.collectionReference.document(id)
    }

    init(id: String, from data: Model) {
        self.data = data
        super.init()
        self.documentReference = Model.collectionReference.document(id)
    }

    required init?(id: String, from data: [String: Any]) {
        do {
            self.data = try Firestore.Decoder().decode(Model.self, from: data)
        } catch (let error) {
            print(error)
            return nil
        }
        super.init()
        self.documentReference = Model.collectionReference.document(id)
    }

    init?(snapshot: DocumentSnapshot) {
        guard let data: [String: Any] = snapshot.data() else {
            super.init()
            self.snapshot = snapshot
            self.documentReference = Model.collectionReference.document(snapshot.documentID)
            return
        }
        do {
            self.data = try Firestore.Decoder().decode(Model.self, from: data)
        } catch (let error) {
            print(error)
            return nil
        }
        super.init()
        self.snapshot = snapshot
        self.documentReference = Model.collectionReference.document(id)
    }

    subscript<T: Any>(keyPath: WritableKeyPath<Model, T>) -> T? {
        get {
            return self.data?[keyPath: keyPath]
        }
        set {
            self.data![keyPath: keyPath] = newValue!
        }
    }
}

// MARK: -

public extension Document {

    func save(reference: DocumentReference? = nil, completion: ((Error?) -> Void)? = nil) {
        let batch: Batch = Batch()
        batch.save(document: self)
        batch.commit(completion)
    }

    func update(reference: DocumentReference? = nil, completion: ((Error?) -> Void)? = nil) {
        let batch: Batch = Batch()
        batch.update(document: self)
        batch.commit(completion)
    }

    func delete(reference: DocumentReference? = nil, completion: ((Error?) -> Void)? = nil) {
        let batch: Batch = Batch()
        batch.delete(document: self)
        batch.commit(completion)
    }
}

// MARK: -

public extension Document {

    class func get(id: String, cachePolicy: CachePolicy = .default, completion: @escaping ((Document?, Error?) -> Void)) {

        switch cachePolicy {
        case .default:
            if let document: Document = self.get(id: id) {
                completion(document, nil)
            }
            Model.collectionReference.document(id).getDocument { (snapshot, error) in
                if let error = error {
                    completion(nil, error)
                    return
                }
                guard let document: Document = Document(snapshot: snapshot!) else {
                    completion(nil, DocumentError.invalidData)
                    return
                }
                completion(document, nil)
            }
        case .cacheOnly:
            if let document: Document = self.get(id: id) {
                completion(document, nil)
            }
            Model.collectionReference.document(id).getDocument(source: FirestoreSource.cache) { (snapshot, error) in
                if let error = error {
                    completion(nil, error)
                    return
                }
                guard let document: Document = Document(snapshot: snapshot!) else {
                    completion(nil, DocumentError.invalidData)
                    return
                }
                completion(document, nil)
            }
        case .networkOnly:
            Model.collectionReference.document(id).getDocument(source: FirestoreSource.server) { (snapshot, error) in
                if let error = error {
                    completion(nil, error)
                    return
                }
                guard let document: Document = Document(snapshot: snapshot!) else {
                    completion(nil, DocumentError.invalidData)
                    return
                }
                completion(document, nil)
            }
        }
    }

    class func get(id: String) -> Document? {
        return Store.shared.get(documentType: self, id: id)
    }

    class func listen(id: String, includeMetadataChanges: Bool = true, completion: @escaping ((Document?, Error?) -> Void)) -> Disposer {
        let listenr: ListenerRegistration = Model.collectionReference.document(id).addSnapshotListener(includeMetadataChanges: includeMetadataChanges) { (snapshot, error) in
            if let error = error {
                completion(nil, error)
                return
            }
            guard let document: Document = Document(snapshot: snapshot!) else {
                completion(nil, DocumentError.invalidData)
                return
            }
            completion(document, nil)
        }
        return Disposer(.value(listenr))
    }
}

public extension Document {

    static var query: DataSource<Model>.Query {
        return DataSource.Query(Model.collectionReference)
    }

    static func `where`(_ keyPath: PartialKeyPath<Model>, isEqualTo: Any) -> DataSource<Model>.Query {
        guard let key: String = keyPath._kvcKeyPathString else {
            fatalError("[Pring.Document] 'keyPath' is not used except for OjbC.")
        }
        return self.where(key, isEqualTo: isEqualTo)
    }

    static func `where`(_ keyPath: PartialKeyPath<Model>, isLessThan: Any) -> DataSource<Model>.Query {
        guard let key: String = keyPath._kvcKeyPathString else {
            fatalError("[Pring.Document] 'keyPath' is not used except for OjbC.")
        }
        return self.where(key, isLessThan: isLessThan)
    }

    static func `where`(_ keyPath: PartialKeyPath<Model>, isLessThanOrEqualTo: Any) -> DataSource<Model>.Query {
        guard let key: String = keyPath._kvcKeyPathString else {
            fatalError("[Pring.Document] 'keyPath' is not used except for OjbC.")
        }
        return self.where(key, isLessThanOrEqualTo: isLessThanOrEqualTo)
    }

    static func `where`(_ keyPath: PartialKeyPath<Model>, isGreaterThan: Any) -> DataSource<Model>.Query {
        guard let key: String = keyPath._kvcKeyPathString else {
            fatalError("[Pring.Document] 'keyPath' is not used except for OjbC.")
        }
        return self.where(key, isGreaterThan: isGreaterThan)
    }

    static func `where`(_ keyPath: PartialKeyPath<Model>, isGreaterThanOrEqualTo: Any) -> DataSource<Model>.Query {
        guard let key: String = keyPath._kvcKeyPathString else {
            fatalError("[Pring.Document] 'keyPath' is not used except for OjbC.")
        }
        return self.where(key, isGreaterThanOrEqualTo: isGreaterThanOrEqualTo)
    }

    static func `where`(_ keyPath: PartialKeyPath<Model>, arrayContains: Any) -> DataSource<Model>.Query {
        guard let key: String = keyPath._kvcKeyPathString else {
            fatalError("[Pring.Document] 'keyPath' is not used except for OjbC.")
        }
        return self.where(key, arrayContains: arrayContains)
    }

    static func order(by: PartialKeyPath<Model>) -> DataSource<Model>.Query {
        guard let key: String = by._kvcKeyPathString else {
            fatalError("[Pring.Document] 'keyPath' is not used except for OjbC.")
        }
        return self.order(by: key)
    }

    static func order(by: PartialKeyPath<Model>, descending: Bool) -> DataSource<Model>.Query {
        guard let key: String = by._kvcKeyPathString else {
            fatalError("[Pring.Document] 'keyPath' is not used except for OjbC.")
        }
        return self.order(by: key, descending: descending)
    }

    // MARK:

    static func `where`(_ field: String, isEqualTo: Any) -> DataSource<Model>.Query {
        return DataSource.Query(Model.collectionReference.whereField(field, isEqualTo: isEqualTo), reference: Model.collectionReference)
    }

    static func `where`(_ field: String, isLessThan: Any) -> DataSource<Model>.Query {
        return DataSource.Query(Model.collectionReference.whereField(field, isLessThan: isLessThan), reference: Model.collectionReference)
    }

    static func `where`(_ field: String, isLessThanOrEqualTo: Any) -> DataSource<Model>.Query {
        return DataSource.Query(Model.collectionReference.whereField(field, isLessThanOrEqualTo: isLessThanOrEqualTo), reference: Model.collectionReference)
    }

    static func `where`(_ field: String, isGreaterThan: Any) -> DataSource<Model>.Query {
        return DataSource.Query(Model.collectionReference.whereField(field, isGreaterThan: isGreaterThan), reference: Model.collectionReference)
    }

    static func `where`(_ field: String, isGreaterThanOrEqualTo: Any) -> DataSource<Model>.Query {
        return DataSource.Query(Model.collectionReference.whereField(field, isGreaterThanOrEqualTo: isGreaterThanOrEqualTo), reference: Model.collectionReference)
    }

    static func `where`(_ field: String, arrayContains: Any) -> DataSource<Model>.Query {
        return DataSource.Query(Model.collectionReference.whereField(field, arrayContains: arrayContains), reference: Model.collectionReference)
    }

    static func order(by: String) -> DataSource<Model>.Query {
        return DataSource.Query(Model.collectionReference.order(by: by), reference: Model.collectionReference)
    }

    static func order(by: String, descending: Bool) -> DataSource<Model>.Query {
        return DataSource.Query(Model.collectionReference.order(by: by, descending: descending), reference: Model.collectionReference)
    }

    // MARK: -

    static func limit(to: Int) -> DataSource<Model>.Query {
        return DataSource.Query(Model.collectionReference.limit(to: to), reference: Model.collectionReference)
    }

    static func start(at: [Any]) -> DataSource<Model>.Query {
        return DataSource.Query(Model.collectionReference.start(at: at), reference: Model.collectionReference)
    }

    static func start(after: [Any]) -> DataSource<Model>.Query {
        return DataSource.Query(Model.collectionReference.start(after: after), reference: Model.collectionReference)
    }

    static func start(atDocument: DocumentSnapshot) -> DataSource<Model>.Query {
        return DataSource.Query(Model.collectionReference.start(atDocument: atDocument), reference: Model.collectionReference)
    }

    static func start(afterDocument: DocumentSnapshot) -> DataSource<Model>.Query {
        return DataSource.Query(Model.collectionReference.start(afterDocument: afterDocument), reference: Model.collectionReference)
    }

    static func end(at: [Any]) -> DataSource<Model>.Query {
        return DataSource.Query(Model.collectionReference.end(at: at), reference: Model.collectionReference)
    }

    static func end(atDocument: DocumentSnapshot) -> DataSource<Model>.Query {
        return DataSource.Query(Model.collectionReference.end(atDocument: atDocument), reference: Model.collectionReference)
    }

    static func end(before: [Any]) -> DataSource<Model>.Query {
        return DataSource.Query(Model.collectionReference.end(before: before), reference: Model.collectionReference)
    }

    static func end(beforeDocument: DocumentSnapshot) -> DataSource<Model>.Query {
        return DataSource.Query(Model.collectionReference.end(beforeDocument: beforeDocument), reference: Model.collectionReference)
    }
}
