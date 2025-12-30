import Contacts
import Foundation

// MARK: - Contacts Provider

actor ContactsProvider {
    private let store = CNContactStore()
    private var isAuthorized = false

    // MARK: - Authorization

    private func requestAccess() async -> Bool {
        if isAuthorized { return true }

        do {
            isAuthorized = try await store.requestAccess(for: .contacts)
            return isAuthorized
        } catch {
            print("Contacts access error: \(error)")
            return false
        }
    }

    // MARK: - Search Contacts

    func search(query: String) async -> ToolExecutionResult {
        guard await requestAccess() else {
            return .error("Contacts access denied. Grant access in System Settings > Privacy > Contacts.")
        }

        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor,
            CNContactBirthdayKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor
        ]

        let predicate = CNContact.predicateForContacts(matchingName: query)

        do {
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keysToFetch)

            if contacts.isEmpty {
                return .text("No contacts found matching '\(query)'")
            }

            let contactInfos = contacts.prefix(10).map { contact -> ContactInfo in
                let fullName = [contact.givenName, contact.familyName]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")

                let phones = contact.phoneNumbers.map { phone -> String in
                    let label = CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: phone.label ?? "")
                    return "\(label): \(phone.value.stringValue)"
                }

                let emails = contact.emailAddresses.map { email -> String in
                    let label = CNLabeledValue<NSString>.localizedString(forLabel: email.label ?? "")
                    return "\(label): \(email.value as String)"
                }

                var address: String? = nil
                if let postal = contact.postalAddresses.first?.value {
                    address = CNPostalAddressFormatter.string(from: postal, style: .mailingAddress)
                        .replacingOccurrences(of: "\n", with: ", ")
                }

                var birthday: String? = nil
                if let bday = contact.birthday {
                    let formatter = DateFormatter()
                    formatter.dateStyle = .medium
                    if let date = Calendar.current.date(from: bday) {
                        birthday = formatter.string(from: date)
                    }
                }

                return ContactInfo(
                    id: contact.identifier,
                    name: fullName.isEmpty ? contact.organizationName : fullName,
                    nickname: contact.nickname.isEmpty ? nil : contact.nickname,
                    organization: contact.organizationName.isEmpty ? nil : contact.organizationName,
                    jobTitle: contact.jobTitle.isEmpty ? nil : contact.jobTitle,
                    phones: phones,
                    emails: emails,
                    address: address,
                    birthday: birthday
                )
            }

            return .contacts(Array(contactInfos))
        } catch {
            return .error("Failed to search contacts: \(error.localizedDescription)")
        }
    }
}

// MARK: - Contact Info Model

struct ContactInfo: Identifiable {
    let id: String
    let name: String
    let nickname: String?
    let organization: String?
    let jobTitle: String?
    let phones: [String]
    let emails: [String]
    let address: String?
    let birthday: String?
}
