import Foundation

/// The database layout. Version 1.
///
/// Everything is keyed by the recipe's UUID. Ingredients, steps and tips are
/// one row each (not blobs of text), which is what makes ingredient search
/// possible: each ingredient row also gets one or more rows in
/// `ingredient_term` holding the plain ingredient name used for matching
/// (see IngredientNormalizer).
///
/// Pictures: `photo` holds the (up to 10) pictures added to a recipe. A
/// picture can be tied to one ingredient or one step; with neither, it
/// belongs to the recipe as a whole. `source_image` holds the photo(s) the
/// recipe was read from. In both, a picture is either a file in the app's
/// photo folder (`storage = 'file'`, `location` = file name — used for
/// camera shots) or a reference to the photo library (`storage = 'asset'`,
/// `location` = the library item's identifier — used for library picks).
enum RecipeSchema {
    static let currentVersion = 3

    // Keep this a plain string of SQL: Tools/search_prototype/schema_test.py
    // extracts it and runs it against SQLite to check it.
    static let version1 = """
    CREATE TABLE recipe (
        id               TEXT PRIMARY KEY,
        title            TEXT NOT NULL DEFAULT '',
        description      TEXT,
        servings         TEXT,
        prep_time        TEXT,
        cook_time        TEXT,
        total_time       TEXT,
        source           TEXT,
        source_text      TEXT,
        excluded_regions TEXT,
        stitch_overlap   INTEGER NOT NULL DEFAULT 0,
        created_at       REAL NOT NULL,
        updated_at       REAL NOT NULL
    );
    CREATE INDEX recipe_title ON recipe(title COLLATE NOCASE);

    CREATE TABLE ingredient (
        id          TEXT PRIMARY KEY,
        recipe_id   TEXT NOT NULL REFERENCES recipe(id) ON DELETE CASCADE,
        group_index INTEGER NOT NULL,
        group_name  TEXT NOT NULL DEFAULT '',
        position    INTEGER NOT NULL,
        text        TEXT NOT NULL
    );
    CREATE INDEX ingredient_recipe ON ingredient(recipe_id, position);

    CREATE TABLE ingredient_term (
        ingredient_id TEXT NOT NULL REFERENCES ingredient(id) ON DELETE CASCADE,
        recipe_id     TEXT NOT NULL REFERENCES recipe(id) ON DELETE CASCADE,
        term          TEXT NOT NULL
    );
    CREATE INDEX ingredient_term_term ON ingredient_term(term);
    CREATE INDEX ingredient_term_recipe ON ingredient_term(recipe_id);

    CREATE TABLE step (
        id          TEXT PRIMARY KEY,
        recipe_id   TEXT NOT NULL REFERENCES recipe(id) ON DELETE CASCADE,
        group_index INTEGER NOT NULL,
        group_name  TEXT NOT NULL DEFAULT '',
        position    INTEGER NOT NULL,
        text        TEXT NOT NULL
    );
    CREATE INDEX step_recipe ON step(recipe_id, position);

    CREATE TABLE tip (
        id        TEXT PRIMARY KEY,
        recipe_id TEXT NOT NULL REFERENCES recipe(id) ON DELETE CASCADE,
        position  INTEGER NOT NULL,
        text      TEXT NOT NULL
    );

    CREATE TABLE nutrition (
        id        TEXT PRIMARY KEY,
        recipe_id TEXT NOT NULL REFERENCES recipe(id) ON DELETE CASCADE,
        position  INTEGER NOT NULL,
        label     TEXT NOT NULL,
        value     TEXT NOT NULL DEFAULT ''
    );

    CREATE TABLE photo (
        id            TEXT PRIMARY KEY,
        recipe_id     TEXT NOT NULL REFERENCES recipe(id) ON DELETE CASCADE,
        position      INTEGER NOT NULL,
        storage       TEXT NOT NULL CHECK (storage IN ('file', 'asset')),
        location      TEXT NOT NULL,
        ingredient_id TEXT REFERENCES ingredient(id) ON DELETE SET NULL,
        step_id       TEXT REFERENCES step(id) ON DELETE SET NULL,
        caption       TEXT NOT NULL DEFAULT '',
        CHECK (ingredient_id IS NULL OR step_id IS NULL)
    );
    CREATE INDEX photo_recipe ON photo(recipe_id, position);
    CREATE INDEX photo_ingredient ON photo(ingredient_id);
    CREATE INDEX photo_step ON photo(step_id);

    CREATE TRIGGER photo_limit BEFORE INSERT ON photo
    WHEN (SELECT COUNT(*) FROM photo WHERE recipe_id = NEW.recipe_id) >= 10
    BEGIN
        SELECT RAISE(ABORT, 'A recipe can have at most 10 pictures');
    END;

    CREATE TABLE source_image (
        recipe_id TEXT NOT NULL REFERENCES recipe(id) ON DELETE CASCADE,
        position  INTEGER NOT NULL,
        storage   TEXT NOT NULL CHECK (storage IN ('file', 'asset')),
        location  TEXT NOT NULL,
        PRIMARY KEY (recipe_id, position)
    );
    """

    /// Version 2: which group a recipe is filed under on the main page
    /// (Breakfast, Dinner, …; empty = uncategorized).
    static let version2 = """
    ALTER TABLE recipe ADD COLUMN category TEXT NOT NULL DEFAULT '';
    CREATE INDEX recipe_category ON recipe(category COLLATE NOCASE);
    """

    /// Version 3: the groups on the main page, stored so they can be
    /// renamed and put in any order. Seeded with the default groups, then
    /// any category already used by a saved recipe.
    static let version3 = """
    CREATE TABLE category (
        name     TEXT PRIMARY KEY COLLATE NOCASE,
        position INTEGER NOT NULL
    );
    INSERT INTO category (name, position) VALUES
        ('Breakfast', 0), ('Lunch', 1), ('Dinner', 2), ('Dessert', 3), ('Snacks', 4);
    INSERT OR IGNORE INTO category (name, position)
        SELECT MIN(category), 100 + ROW_NUMBER() OVER (ORDER BY category COLLATE NOCASE)
        FROM recipe WHERE category <> '' GROUP BY category COLLATE NOCASE;
    """
}
