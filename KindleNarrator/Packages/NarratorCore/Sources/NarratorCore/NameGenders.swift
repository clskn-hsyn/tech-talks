import Foundation

/// A small list of common English first names, used only as a tie-breaker when a character's
/// gender hasn't been established from the text (honorifics, "she said") or the language model.
enum NameGenders {
    static func gender(ofFirstName name: String) -> Gender {
        guard let first = name.split(separator: " ").first.map(String.init) else { return .unknown }
        if female.contains(first) { return .female }
        if male.contains(first) { return .male }
        return .unknown
    }

    static let female: Set<String> = [
        "Abigail", "Ada", "Agnes", "Alice", "Amelia", "Amy", "Anna", "Anne", "Ava", "Beatrice", "Bella",
        "Beth", "Bridget", "Caroline", "Catherine", "Charlotte", "Chloe", "Claire", "Clara", "Daisy",
        "Diana", "Dorothy", "Edith", "Eleanor", "Elena", "Elinor", "Eliza", "Elizabeth", "Ella", "Ellen",
        "Emily", "Emma", "Esther", "Eva", "Evelyn", "Fanny", "Grace", "Hannah", "Harriet", "Helen",
        "Hermione", "Isabel", "Isabella", "Jane", "Jennifer", "Jess", "Jessica", "Jo", "Josephine", "Julia",
        "Juliet", "Kate", "Katherine", "Kitty", "Laura", "Leah", "Lily", "Lizzy", "Lucy", "Lydia", "Maggie",
        "Margaret", "Maria", "Marianne", "Marie", "Martha", "Mary", "Matilda", "Meg", "Mia", "Molly",
        "Nancy", "Natalie", "Nora", "Olivia", "Rachel", "Rebecca", "Rose", "Ruth", "Sara", "Sarah",
        "Sophia", "Sophie", "Susan", "Victoria", "Violet", "Zoe",
    ]

    static let male: Set<String> = [
        "Adam", "Albert", "Alexander", "Alfred", "Andrew", "Arthur", "Ben", "Benjamin", "Bill", "Bob",
        "Charles", "Charlie", "Chris", "Daniel", "David", "Edmund", "Edward", "Fred", "Frederick",
        "George", "Harry", "Henry", "Hugh", "Jack", "Jacob", "James", "Jim", "Joe", "John", "Jonathan",
        "Joseph", "Leo", "Liam", "Louis", "Luke", "Mark", "Matthew", "Michael", "Nathan", "Ned", "Nick",
        "Noah", "Oliver", "Oscar", "Patrick", "Paul", "Peter", "Philip", "Ralph", "Richard", "Robert",
        "Ron", "Sam", "Samuel", "Sebastian", "Simon", "Stephen", "Thomas", "Tim", "Tom", "Victor",
        "Walter", "William", "Will",
    ]
}
