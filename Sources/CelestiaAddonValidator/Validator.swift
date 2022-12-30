import Foundation
import OpenCloudKit
import ZIPFoundation

public enum ValidatorError: Error {
    case noIDOrIncorrectIDProvidedForRemoval
    case incorrectIDRequirementFormat
    case missingFields(fieldName: String)
    case emptyResult
    case fileManager
    case unzipping
}

extension ValidatorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noIDOrIncorrectIDProvidedForRemoval:
            return "No ID or incorrect ID provided for add-on removal"
        case .incorrectIDRequirementFormat:
            return "Incorrect ID requirement format"
        case .missingFields(let fieldName):
            return "Missing fields, field name: \(fieldName)"
        case .emptyResult:
            return "Empty result returned"
        case .fileManager:
            return "File manager error"
        case .unzipping:
            return "Error unzipping item"
        }
    }
}

public final class Validator {
    public init() {}

    public static func configure(_ config: CKContainerConfig) {
        CloudKit.shared.configure(with: CKConfig(containers: [config]))
    }

    public func validate(recordID: CKRecord.ID) async throws -> ItemOperation {
        let db = CKContainer.default().publicCloudDatabase
        let recordFetchResult = try await db.records(for: [recordID])[recordID]
        guard let recordFetchResult else {
            throw UploaderError.emptyResult
        }
        switch recordFetchResult {
        case .success(let record):
            return try await validate(record: record)
        case .failure(let error):
            throw error
        }
    }

    public func validate(zipFilePath: String) throws -> ItemOperation {
        let temporaryDirectoryPath = (NSTemporaryDirectory() as NSString).appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: temporaryDirectoryPath, withIntermediateDirectories: true)
        } catch {
            throw ValidatorError.fileManager
        }
        do {
            try fm.unzipItem(at: URL(fileURLWithPath: zipFilePath), to: URL(fileURLWithPath: temporaryDirectoryPath))
        } catch {
            throw ValidatorError.unzipping
        }
        var basePath = temporaryDirectoryPath
        var contents = [String]()
        while true {
            do {
                contents = try fm.contentsOfDirectory(atPath: basePath)
            } catch {
                throw ValidatorError.fileManager
            }
            if contents.count == 1 {
                var isDir: ObjCBool = false
                // Real content might be one level inside the zip
                let potentialPath = (basePath as NSString).appendingPathComponent(contents[0])
                if fm.fileExists(atPath: potentialPath, isDirectory: &isDir), isDir.boolValue, contents[0] != "rich_description" {
                    basePath = potentialPath
                }
            } else {
                break
            }
        }
        return try validateDirectory(basePath)
    }

    private func validateDirectory(_ path: String) throws -> ItemOperation {
        let category = readString(directoryPath: path, filename: "category.txt")
        let idRequirement = readString(directoryPath: path, filename: "id_requirement.txt") ?? readString(directoryPath: path, filename: "id.txt")
        if let category, category.isEmpty {
            // This is a remove operation, should only check id_requirement
            guard let idRequirement, idRequirement.count == UUID().uuidString.count else {
                throw ValidatorError.noIDOrIncorrectIDProvidedForRemoval
            }
            // TODO: we could check the ID is valid or not by fetch the add-on
            return .remove(item: RemoveItem(id: CKRecord.ID(recordName: idRequirement)))
        }
        let authors = readStringList(directoryPath: path, filename: "authors.txt")
        let releaseDate = readDate(directoryPath: path, filename: "release_date.txt")
        let lastUpdateDate = readDate(directoryPath: path, filename: "last_update_date.txt")
        let demoObjectName = readString(directoryPath: path, filename: "demo_object_name.txt")
        let title = readString(directoryPath: path, filename: "title.txt")
        let description = readString(directoryPath: path, filename: "description.txt")
        let potentialAddonPath = (path as NSString).appendingPathComponent("addon.zip")
        let addonURL = FileManager.default.fileExists(atPath: potentialAddonPath) ? URL(fileURLWithPath: potentialAddonPath) : nil

        let potentialCoverImagePath = (path as NSString).appendingPathComponent("cover_image.jpg")
        let coverImageURL = FileManager.default.fileExists(atPath: potentialCoverImagePath) ? URL(fileURLWithPath: potentialCoverImagePath) : nil

        let modifyingExistingAddon: Bool
        if let idRequirement {
            if idRequirement.count == UUID().uuidString.count {
                modifyingExistingAddon = true
            } else {
                guard idRequirement.allSatisfy({ character in "0123456789ABCDEF".contains(where: { $0 == character }) }) else {
                    throw ValidatorError.incorrectIDRequirementFormat
                }
                guard idRequirement.count <= UUID().uuidString.split(separator: "-")[0].count else {
                    throw ValidatorError.incorrectIDRequirementFormat
                }
                modifyingExistingAddon = false
            }
        } else {
            modifyingExistingAddon = false
        }

        let richDescriptionDirectory = (path as NSString).appendingPathComponent("rich_description")
        var isDirectory: ObjCBool = false
        let richDescription: RichDescription?
        if FileManager.default.fileExists(atPath: richDescriptionDirectory, isDirectory: &isDirectory), isDirectory.boolValue {
            let baseContent = readString(directoryPath: richDescriptionDirectory, filename: "base.txt")!
            let notes = readStringList(directoryPath: richDescriptionDirectory, filename: "notes.txt")
            let richCoverImagePath = (richDescriptionDirectory as NSString).appendingPathComponent("cover_image.jpg")
            let richCoverText = readString(directoryPath: richDescriptionDirectory, filename: "cover_image.txt")
            guard FileManager.default.fileExists(atPath: richCoverImagePath) else {
                throw ValidatorError.missingFields(fieldName: "rich_description/cover_image.jpg")
            }
            let youtubeIDs = readStringList(directoryPath: richDescriptionDirectory, filename: "youtube_ids.txt")
            var images = [Image]()
            while true {
                let imagePath = (richDescriptionDirectory as NSString).appendingPathComponent("detail_image_\(images.count).jpg")
                if !FileManager.default.fileExists(atPath: imagePath) {
                    break
                }
                let caption = readString(directoryPath: richDescriptionDirectory, filename: "detail_image_\(images.count).txt")
                images.append(Image(imageURL: URL(fileURLWithPath: imagePath), caption: caption))
            }
            let additionalLeadingHTML = readString(directoryPath: richDescriptionDirectory, filename: "additional_leading.html")
            let additionalTrailingHTML = readString(directoryPath: richDescriptionDirectory, filename: "additional_trailing.html")

            richDescription = RichDescription(base: baseContent, notes: notes, coverImage: Image(imageURL: URL(fileURLWithPath: richCoverImagePath), caption: richCoverText), detailImages: images.isEmpty ? nil : images, youtubeIDs: youtubeIDs, additionalLeadingHTML: additionalLeadingHTML, additionalTrailingHTML: additionalTrailingHTML)
        } else {
            richDescription = nil
        }

        if !modifyingExistingAddon {
            guard let title else {
                throw ValidatorError.missingFields(fieldName: "title.txt")
            }
            guard let description else {
                throw ValidatorError.missingFields(fieldName: "description.txt")
            }
            guard let category else {
                throw ValidatorError.missingFields(fieldName: "category.txt")
            }
            guard let authors else {
                throw ValidatorError.missingFields(fieldName: "authors.txt")
            }
            guard let releaseDate else {
                throw ValidatorError.missingFields(fieldName: "release_date.txt")
            }
            guard let coverImageURL else {
                throw ValidatorError.missingFields(fieldName: "cover_image.jpg")
            }
            guard let addonURL else {
                throw ValidatorError.missingFields(fieldName: "addon.zip")
            }
            return .create(item: CreateItem(title: title, category: CKRecord.Reference(recordID: CKRecord.ID(recordName: category), action: .none), idRequirement: idRequirement, authors: authors, description: description, demoObjectName: demoObjectName, releaseDate: releaseDate, lastUpdateDate: lastUpdateDate, coverImage: coverImageURL, addon: addonURL, richDescription: richDescription))
        }
        guard let idRequirement else {
            throw ValidatorError.missingFields(fieldName: "id_requirement.txt")
        }
        let categoryReference: CKRecord.Reference?
        if let category, !category.isEmpty {
            categoryReference = CKRecord.Reference(recordID: CKRecord.ID(recordName: category), action: .none)
        } else {
            categoryReference = nil
        }
        return .update(item: UpdateItem(title: title, category: categoryReference, id: CKRecord.ID(recordName: idRequirement), authors: authors, description: description, demoObjectName: demoObjectName, releaseDate: releaseDate, lastUpdateDate: lastUpdateDate, coverImage: coverImageURL, addon: addonURL, richDescription: richDescription))
    }

    public func validate(record: CKRecord) async throws -> ItemOperation {
        let remove = record["remove"] as? Bool
        let idRequirement = record["id_requirement"] as? String
        if let remove, remove {
            // This is a remove operation, should only check id_requirement
            print("Parsing remove item...")
            guard let idRequirement, idRequirement.count == UUID().uuidString.count else {
                throw ValidatorError.noIDOrIncorrectIDProvidedForRemoval
            }
            // TODO: we could check the ID is valid or not by fetch the add-on
            return .remove(item: RemoveItem(id: CKRecord.ID(recordName: idRequirement)))
        }
        let modifyingExistingAddon: Bool
        if let idRequirement {
            if idRequirement.count == UUID().uuidString.count {
                modifyingExistingAddon = true
            } else {
                guard idRequirement.allSatisfy({ character in "0123456789ABCDEF".contains(where: { $0 == character }) }) else {
                    throw ValidatorError.incorrectIDRequirementFormat
                }
                guard idRequirement.count <= UUID().uuidString.split(separator: "-")[0].count else {
                    throw ValidatorError.incorrectIDRequirementFormat
                }
                modifyingExistingAddon = false
            }
        } else {
            modifyingExistingAddon = false
        }

        let richDescription: RichDescription?
        if let baseContent = record["rich_description_base"] as? String {
            // Parse rich description...
            print("Parsing rich description...")

            guard let coverImageURL = (record["rich_description_cover_image"] as? CKAsset)?.fileURL else {
                throw ValidatorError.missingFields(fieldName: "rich_description_cover_image")
            }
            let notes = record["rich_description_notes"] as? [String]
            let coverImageCaption = record["rich_description_cover_image_caption"] as? String
            let youtubeIDs = record["rich_description_youtube_ids"] as? [String]
            let additionalLeadingHTML = record["rich_description_additional_leading"] as? String
            let additionalTrailingHTML = record["rich_description_additional_trailing"] as? String
            let detailCoverImageCaptions = record["rich_description_detail_image_captions"] as? [String]
            let detailCoverImages = record["rich_description_detail_images"] as? [CKAsset]

            var detailImages: [Image] = []
            if let detailCoverImages {
                for (index, detailCoverImage) in detailCoverImages.enumerated() {
                    if let detailCoverImageCaptions, detailCoverImageCaptions.count > index {
                        detailImages.append(Image(imageURL: detailCoverImage.fileURL, caption: detailCoverImageCaptions[index]))
                    } else {
                        detailImages.append(Image(imageURL: detailCoverImage.fileURL, caption: nil))
                    }
                }
            }

            richDescription = RichDescription(base: baseContent, notes: notes, coverImage: Image(imageURL: coverImageURL, caption: coverImageCaption), detailImages: detailImages.isEmpty ? nil : detailImages, youtubeIDs: youtubeIDs, additionalLeadingHTML: additionalLeadingHTML, additionalTrailingHTML: additionalTrailingHTML)
        } else {
            richDescription = nil
        }

        // Parse main contents...
        print("Parsing main contents...")
        let title = record["title"] as? String
        let description = record["description"] as? String
        let category = record["category"] as? CKRecord.Reference
        let releaseDate = record["release_date"] as? Date
        let lastUpdateDate = record["last_update_date"] as? Date
        let authors = record["authors"] as? [String]
        let addonURL = (record["addon"] as? CKAsset)?.fileURL
        let demoObjectName = record["demo_object_name"] as? String
        let coverImageURL = (record["cover_image"] as? CKAsset)?.fileURL

        if !modifyingExistingAddon {
            guard let title else {
                throw ValidatorError.missingFields(fieldName: "title")
            }
            guard let description else {
                throw ValidatorError.missingFields(fieldName: "description")
            }
            guard let category else {
                throw ValidatorError.missingFields(fieldName: "category")
            }
            guard let authors else {
                throw ValidatorError.missingFields(fieldName: "authors")
            }
            guard let releaseDate else {
                throw ValidatorError.missingFields(fieldName: "release_date")
            }
            guard let coverImageURL else {
                throw ValidatorError.missingFields(fieldName: "cover_image")
            }
            guard let addonURL else {
                throw ValidatorError.missingFields(fieldName: "addon")
            }
            return .create(item: CreateItem(title: title, category: category, idRequirement: idRequirement, authors: authors, description: description, demoObjectName: demoObjectName, releaseDate: releaseDate, lastUpdateDate: lastUpdateDate, coverImage: coverImageURL, addon: addonURL, richDescription: richDescription))
        }
        guard let idRequirement else {
            throw ValidatorError.missingFields(fieldName: "id_requirement")
        }
        return .update(item: UpdateItem(title: title, category: category, id: CKRecord.ID(recordName: idRequirement), authors: authors, description: description, demoObjectName: demoObjectName, releaseDate: releaseDate, lastUpdateDate: lastUpdateDate, coverImage: coverImageURL, addon: addonURL, richDescription: richDescription))
    }
}

extension Validator {
    private func readString(directoryPath: String, filename: String) -> String? {
        let file = (directoryPath as NSString).appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: file) {
            return nil
        }
        let contents = try! Data(contentsOf: URL(fileURLWithPath: file))
        return String(data: contents, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readStringList(directoryPath: String, filename: String) -> [String]? {
        let file = (directoryPath as NSString).appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: file) {
            return nil
        }
        let contents = try! Data(contentsOf: URL(fileURLWithPath: file))
        return String(data: contents, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n").map({ String($0) }).filter { !$0.isEmpty }
    }

    private func readDate(directoryPath: String, filename: String) -> Date? {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        dateFormatter.timeZone = TimeZone(identifier: "GMT")
        let file = (directoryPath as NSString).appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: file) {
            return nil
        }
        let contents = try! Data(contentsOf: URL(fileURLWithPath: file))
        let string = String(data: contents, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
        return dateFormatter.date(from: string)!
    }
}
