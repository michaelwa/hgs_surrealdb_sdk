INFO FOR ROOT;
INFO FOR NS;
INFO FOR DB;

-- REMOVE TABLE user_profile;

create_user_profile_table = """
DEFINE TABLE user_profile TYPE NORMAL SCHEMAFULL PERMISSIONS NONE;
DEFINE FIELD email ON user_profile TYPE STRING ASSERT $value.is_email();
DEFINE FIELD first_name ON user_profile TYPE STRING ASSERT $value.replace(\" \", \"\").replace(\"-\", \"\").is_alpha();
DEFINE FIELD last_name ON user_profile TYPE STRING ASSERT $value.replace(\" \", \"\").replace(\"-\", \"\").is_alpha();
DEFINE FIELD middle_name ON user_profile TYPE OPTION<STRING> ASSERT $value.replace(\" \", \"\").replace(\"-\", \"\").is_alpha();
DEFINE FIELD full_name ON user_profile VALUE ($this.first_name + \" \" + ($this.middle_name ?: + '')  + \" \" + $this.last_name).replace(\"  \", \" \");
DEFINE FIELD created_at ON user_profile TYPE DATETIME READONLY DEFAULT time::now();
DEFINE FIELD updated_at ON user_profile TYPE DATETIME VALUE time::now()
"""

LET $test = \"http://mercurysmith.com\";
parse::url::domain(\"http://mercurysmith.com\");
parse::url::domain($test);

math::max([ 26.164, 13.746189, 23, 16.4, 41.42 ])

-- TODO
-- unique index ON email

INFO FOR TABLE user_profile;

insert_into_user_profile = """
    INSERT INTO user_profile {
        email: "michael.a.johnson.wa@gmail.com",
        first_name: "Michael",
        last_name: "Johnson",
        middle_name: "A"
    };

    INSERT INTO user_profile {
        email: "robert.j.crosby.wa@gmail.com",
        first_name: "Robert",
        last_name: "Crosby",
        middle_name: "J"
    };

    SELECT * FROM user_profile;
"""
-----------------------------------------------------------------------------------------------------------------------------------------------------

REMOVE TABLE user_auth;

DEFINE TABLE user_auth TYPE NORMAL SCHEMAFULL PERMISSIONS NONE;
DEFINE FIELD hashed_password ON user_auth TYPE STRING PERMISSIONS FULL;
DEFINE FIELD is_locked ON user_auth TYPE BOOL PERMISSIONS FULL DEFAULT FALSE;
DEFINE FIELD email_validated_date ON user_auth TYPE option<DATETIME>;
DEFINE FIELD last_successful_login ON user_auth TYPE option<DATETIME>;
DEFINE FIELD failed_login_attempts ON user_auth TYPE INT DEFAULT 0;
DEFINE FIELD password_expiration_date ON user_auth TYPE DATETIME DEFAULT time::now() + 90d;
DEFINE FIELD created_at ON user_auth TYPE DATETIME READONLY DEFAULT time::now();
DEFINE FIELD updated_at ON user_auth TYPE DATETIME VALUE time::now();

INFO FOR TABLE user_auth;

-- TODO 
-- number of successful logins

INSERT INTO user_auth{
    user_profile_id: user_profile:pctl4dwjsiu9xy6r1pt4,
    id: rand::guid(),
    hashed_password: crypto::argon2::generate(\"this is a strong password\"),
};


SELECT 
    created_at as user_profile.created_at, 
    email as user_profile.email,
    first_name as user_profile.first_name,
    id as user_profile.id,
    last_name as user_profile.last_name,
    middle_name as user_profile.middle_name,
    updated_at as user_profile.updated_at, 
    \"create_changeset\" as user_profile._type_changeset
FROM user_profile;

SELECT * FROM user_profile;
SELECT * FROM user_auth;

---

CREATE flow:user_auth
    SET create = 'create_changeset',
        login_post = {
            'MyApp.UserAuth.login',
            'user_name',
            'password'
        }
;

CREATE processes:register
    set inputs = [\"email\", \"first_name\", \"last_name\"],
        http_verb = \"POST\"
    ;


UPDATE processes:register 
    set inputs = [\"email\", \"first_name\", \"last_name\"],
        http_verb = \"POST\"
    ;

    
SELECT * from flow:user_auth;

DELETE flow:user_auth;

RETURN time::now();


-----------------------------------------------------------------------------------------------------------------------------------------------------

-- Define the table 'alltypes' with full schema.
DEFINE TABLE alltypes SCHEMAFULL
    PERMISSIONS
        FOR select FULL,
        FOR create FULL,
        FOR update FULL,
        FOR delete FULL;

-- Define one field per core built-in type.
DEFINE FIELD boolField     ON alltypes TYPE bool;
DEFINE FIELD intField      ON alltypes TYPE int;
DEFINE FIELD floatField    ON alltypes TYPE float;
DEFINE FIELD decimalField  ON alltypes TYPE decimal;
DEFINE FIELD stringField   ON alltypes TYPE string;
DEFINE FIELD durationField ON alltypes TYPE duration;
DEFINE FIELD datetimeField ON alltypes TYPE datetime;
DEFINE FIELD uuidField     ON alltypes TYPE uuid;
DEFINE FIELD arrayField    ON alltypes TYPE array;
DEFINE FIELD objectField   ON alltypes TYPE object;
DEFINE FIELD geomField     ON alltypes TYPE geometry;



-- need user_oauth table
-- need user_saml table

-- how does registration or new account creation work?
    -- invite user workflow
    -- self apply workflow
    -- must accept 'privacy policy' and 'terms of agreement'

-- need user_role table

-- need main db
    -- organizations table
    -- subscriptions
    -- payment methods
    -- contacts
    -- 


-----------------------------------------------------------------------------------------------------------------------------------------------------

DEFINE TABLE chat_room TYPE NORMAL SCHEMAFULL PERMISSIONS NONE;
DEFINE FIELD name ON chat_room TYPE STRING PERMISSIONS FULL;
DEFINE FIELD type ON chat_room TYPE STRING ASSERT [\"direct\", \"group\", \"room\"] PERMISSIONS FULL;
DEFINE FIELD created_at ON chat_room TYPE DATETIME READONLY DEFAULT time::now() PERMISSIONS FULL;
DEFINE FIELD updated_at ON chat_room TYPE DATETIME VALUE time::now() PERMISSIONS FULL;

--todo 
--authorized users 
--direct has two users
--group has more than two users; once created users cannot be added or removed 
--room has dynamic users; users may be added or removed

select * from user_profile;

SELECT * FROM chat_room;

DEFINE TABLE chat_message TYPE RELATION IN user_profile OUT chat_room SCHEMAFULL PERMISSIONS NONE;
DEFINE FIELD message ON chat_message TYPE STRING PERMISSIONS FULL;
DEFINE FIELD created_at ON chat_message TYPE DATETIME READONLY DEFAULT time::now() PERMISSIONS FULL;
DEFINE FIELD updated_at ON chat_message TYPE DATETIME VALUE time::now() PERMISSIONS FULL;


INSERT INTO chat_room {
    name: \"Test_Room\",
    type: \"direct\"
};

RELATE user_profile:rooojawh071fq980pa5p->chat_message:ulid()->chat_room:hgw9t98gobkwnsjbgprk
    CONTENT {
        message: \"Hello\"
    };
RELATE user_profile:ryjvwm8cscamzoj0pg48->chat_message:ulid()->chat_room:hgw9t98gobkwnsjbgprk
    CONTENT {
        message: \"how are you?\"
    };
RELATE user_profile:rooojawh071fq980pa5p->chat_message:ulid()->chat_room:hgw9t98gobkwnsjbgprk
    CONTENT {
        message: \"just fine. how about you?\"
    };
RELATE user_profile:ryjvwm8cscamzoj0pg48->chat_message:ulid()->chat_room:hgw9t98gobkwnsjbgprk
    CONTENT {
        message: \"well enough\"
    };

SELECT <-chat_message.{
\tid,
\tmessage,
\tin.{
\t\tid,
\t\tfull_name
\t}
} AS messages, name AS room_name 
FROM ONLY chat_room WHERE id = chat_room:hgw9t98gobkwnsjbgprk LIMIT 1;

--REMOVE TABLE chat_message;

delete from chat_message where in = NONE;

DEFINE TABLE OVERWRITE test SCHEMAFULL TYPE RELATION IN user_profile OUT chat_message ENFORCED;

select * from chat_message;

select * from user_profile;

select <-chat_message.{id, message}<-chat_message<-user_profile.first_name
from chat_room
where id = chat_room:hgw9t98gobkwnsjbgprk;


select * from user_profile;

INFO FOR DB;
INFO FOR TABLE user_profile;

fn::divide(10, 5);

-- instead of chat_message being a table it could be a releation from user_profile to chat_room
-- the in and out would be readonly
-- message could be edited
-- the chat room would contain the access members at creation 
--    direct would be one to one and allow only two users
--    group would be any subset of users with this the greater oontext
--    room would be all users with in the context and could be topical
--    if a new user is added to the greater context then if they have been invited to the room they have the context 

LET $time = time::now();
RELATE person:l19zjikkw1p1h9o6ixrg->wrote->article:8nkk6uj4yprt49z7y3zm
    CONTENT {
        time: {
            written: $time
        }
    };

REMOVE TABLE chat_message;

DEFINE TABLE chat_message TYPE NORMAL SCHEMAFULL PERMISSIONS FULL;
DEFINE FIELD message ON chat_message TYPE STRING PERMISSIONS FULL;
DEFINE FIELD created_at ON chat_message TYPE DATETIME READONLY DEFAULT time::now() PERMISSIONS FULL;
DEFINE FIELD updated_at ON chat_message TYPE DATETIME VALUE time::now() PERMISSIONS FULL;
DEFINE FIELD from ON chat_message TYPE record<user_profile> PERMISSIONS FULL;

INFO FOR TABLE chat_message;
INFO FOR TABLE chat_room;

SELECT * FROM chat_room WHERE id = 'asdf';

CREATE ONLY chat_room_message:ulid() CONTENT {
    message: \"hello!\",
    from: user_profile:dohs6e5uks42ucm1svh5
};

UPDATE chat_room_message:01JD33T732NHBEBF14EJCV4YG8 SET message = \"Hello world!😎🧒🏻💗\" RETURN AFTER;


-- https://www.prosettings.com/emoji-list/
select * from chat_room_message;
delete chat_room_message;

select * from user_profile;

REMOVE TABLE chat_room;
REMOVE TABLE chat_room_message;



-- kruft below here

TYPE option<array<record<building>>>
ASSERT ['house', 'castle']

INFO FOR DB;
INFO FOR TABLE building;


INSERT INTO cat (id, feet) VALUES (\"mr_meowd\", 4), (\"mrs_meowd\", 4), (\"kittend\", 5);
RELATE [cat:mr_meow, cat:mrs_meow]->parent_of_1:ulid()->cat:kitten;

select * from cat;

INFO FOR TABLE parent_of_1;
SELECT * FROM parent_of_1;

DEFINE TABLE person SCHEMAFULL;
DEFINE TABLE building SCHEMAFULL;
DEFINE FIELD name ON TABLE person 
    TYPE string 
    ASSERT $value.replace(\" \", \"\").replace(\"-\", \"\").is_alpha();
DEFINE FIELD class ON table person TYPE option<string>;
DEFINE FIELD money ON TABLE person 
    TYPE option<int>
    ASSERT $value >= 0 OR $value IS NONE;
DEFINE FIELD name ON TABLE building TYPE string;
DEFINE FIELD kind ON TABLE building 
    TYPE string
    ASSERT 
    [\"house\", \"castle\"] CONTAINS $value;
DEFINE FIELD properties ON TABLE person TYPE option<array<record<building>>>;

-- can this be used to share the id between the reocrds
CREATE bank:first_bank_of_toria, person:aeon, person:customer, person:employee SET name = id.id();
CREATE ONLY person:ulid() CONTENT { 
    name: \"jack\" 
} RETURN AFTER;
CREATE ONLY person:ulid() CONTENT { 
    name: \"michael\" 
} RETURN AFTER;
CREATE ONLY person:ulid() CONTENT { 
    name: \"nathan\" 
} RETURN AFTER;

SELECT * FROM person ORDER BY id;

SELECT id.id() FROM user_profile;

RETURN time::now();


RETURN crypto::argon2::generate(\"this is a strong password\");

LET $hash = \"$argon2id$v=19$m=4096,t=3,p=1$pbZ6yJ2rPJKk4pyEMVwslQ$jHzpsiB+3S/H+kwFXEcr10vmOiDkBkydVCSMfRxV7CA\";
LET $pass = \"this is a strong password\";
RETURN crypto::argon2::compare($hash, $pass);

DEFINE TABLE user_token TYPE NORMAL SCHEMAFULL PERMISSIONS NONE;



",