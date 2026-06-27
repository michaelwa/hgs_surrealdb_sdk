defmodule Mix.Tasks.Surreal.GenContextBuilderTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Surreal.GenContextBuilder, as: Builder
  alias Mix.Tasks.Surreal.GenContextBuilder.Field

  describe "parse_field!/1" do
    test "parses a plain string field" do
      assert %Field{
               name: "name",
               surreal_type: "STRING",
               zoi_base: "Zoi.string()",
               optional?: false,
               modifiers: []
             } = Builder.parse_field!("name:string")
    end

    test "marks ? suffix optional" do
      assert %Field{name: "middle_name", surreal_type: "STRING", optional?: true} =
               Builder.parse_field!("middle_name:string?")
    end

    test "maps integer aliases and other base types" do
      assert %Field{surreal_type: "INT", zoi_base: "Zoi.integer()"} =
               Builder.parse_field!("age:int")

      assert %Field{surreal_type: "INT"} = Builder.parse_field!("age:integer")

      assert %Field{surreal_type: "DATETIME", zoi_base: "Zoi.datetime()"} =
               Builder.parse_field!("at:datetime")

      assert %Field{surreal_type: "ARRAY", zoi_base: "Zoi.array(Zoi.any())"} =
               Builder.parse_field!("tags:array")
    end

    test "parses record:<table> reference type" do
      assert %Field{surreal_type: "record<account>", zoi_base: "Zoi.string()", optional?: true} =
               Builder.parse_field!("owner:record:account?")
    end

    test "parses |-delimited modifiers without splitting SurrealQL ::" do
      assert %Field{
               name: "created_at",
               surreal_type: "DATETIME",
               optional?: false,
               modifiers: [{:readonly, nil}, {:default, "time::now()"}]
             } = Builder.parse_field!("created_at:datetime|readonly|default=time::now()")
    end

    test "raises on missing type" do
      assert_raise Mix.Error, fn -> Builder.parse_field!("name:") end
      assert_raise Mix.Error, fn -> Builder.parse_field!("name") end
    end

    test "raises on bad field name" do
      assert_raise Mix.Error, fn -> Builder.parse_field!("Name:string") end
    end

    test "raises on unknown type" do
      assert_raise Mix.Error, fn -> Builder.parse_field!("name:widget") end
    end

    test "raises on unknown modifier" do
      assert_raise Mix.Error, fn -> Builder.parse_field!("name:string|frobnicate") end
    end
  end

  test "parse_fields!/1 maps a list" do
    assert [%Field{name: "a"}, %Field{name: "b"}] =
             Builder.parse_fields!(["a:string", "b:int"])
  end

  describe "zoi_expr/1" do
    test "returns base for required field" do
      assert "Zoi.string()" == Builder.zoi_expr(Builder.parse_field!("name:string"))
    end

    test "pipes optional for ? field" do
      assert "Zoi.string() |> Zoi.optional()" ==
               Builder.zoi_expr(Builder.parse_field!("nick:string?"))
    end

    test "ignores migration-only modifiers" do
      assert "Zoi.datetime()" ==
               Builder.zoi_expr(Builder.parse_field!("at:datetime|readonly|default=time::now()"))
    end
  end

  describe "define_field_line/2" do
    test "plain required field" do
      assert "DEFINE FIELD name ON user TYPE STRING;" ==
               Builder.define_field_line(Builder.parse_field!("name:string"), "user")
    end

    test "optional wraps in OPTION<>" do
      assert "DEFINE FIELD nick ON user TYPE OPTION<STRING>;" ==
               Builder.define_field_line(Builder.parse_field!("nick:string?"), "user")
    end

    test "emits modifiers in READONLY DEFAULT VALUE ASSERT order" do
      field = Builder.parse_field!("created_at:datetime|default=time::now()|readonly")

      assert "DEFINE FIELD created_at ON user TYPE DATETIME READONLY DEFAULT time::now();" ==
               Builder.define_field_line(field, "user")
    end

    test "emits assert last and value clause" do
      assert "DEFINE FIELD email ON acct TYPE STRING ASSERT $value.is_email();" ==
               Builder.define_field_line(
                 Builder.parse_field!("email:string|assert=$value.is_email()"),
                 "acct"
               )

      assert "DEFINE FIELD updated_at ON acct TYPE DATETIME VALUE time::now();" ==
               Builder.define_field_line(
                 Builder.parse_field!("updated_at:datetime|value=time::now()"),
                 "acct"
               )
    end
  end

  describe "pluralize/1" do
    test "regular adds s" do
      assert "users" == Builder.pluralize("user")
      assert "days" == Builder.pluralize("day")
    end

    test "sibilants add es" do
      assert "classes" == Builder.pluralize("class")
      assert "boxes" == Builder.pluralize("box")
      assert "buzzes" == Builder.pluralize("buzz")
      assert "watches" == Builder.pluralize("watch")
      assert "dishes" == Builder.pluralize("dish")
    end

    test "consonant + y becomes ies" do
      assert "companies" == Builder.pluralize("company")
    end
  end

  describe "table_name/1" do
    test "snake_cases the schema argument" do
      assert "user" == Builder.table_name("User")
      assert "user_profile" == Builder.table_name("UserProfile")
    end
  end

  describe "migration rendering" do
    test "migration_filename joins timestamp and name" do
      assert "20260627000000_create_user.surql" ==
               Builder.migration_filename("20260627000000", "create_user")
    end

    test "migration_body renders up/down with field lines" do
      fields = Builder.parse_fields!(["name:string", "nick:string?"])

      assert Builder.migration_body("user", "create_user", fields) == """
             -- create_user

             -- migrate:up
             DEFINE TABLE user TYPE NORMAL SCHEMAFULL PERMISSIONS NONE;
             DEFINE FIELD name ON user TYPE STRING;
             DEFINE FIELD nick ON user TYPE OPTION<STRING>;

             -- migrate:down
             REMOVE TABLE user;
             """
    end
  end

  describe "schema_module_body/2" do
    test "renders use, table, and Zoi object with id first" do
      fields = Builder.parse_fields!(["name:string", "age:int?"])
      body = Builder.schema_module_body("user", fields)

      assert body =~ "use SurrealDB.Schema"
      assert body =~ ~s(table "user")
      assert body =~ "id: Zoi.string() |> Zoi.optional()"
      assert body =~ "name: Zoi.string()"
      assert body =~ "age: Zoi.integer() |> Zoi.optional()"
      assert body =~ "Zoi.object(%{"
    end
  end

  describe "context_module_body/5" do
    test "renders aliases and delegating CRUD functions" do
      body =
        Builder.context_module_body(
          MyApp.Accounts,
          MyApp.Accounts.User,
          MyApp.SurrealStore,
          "user",
          "users"
        )

      assert body =~ "alias MyApp.Accounts.User"
      assert body =~ "alias MyApp.SurrealStore"
      assert body =~ "def list_users(filters \\\\ %{}), do: SurrealStore.all(User, filters)"
      assert body =~ "def get_user(id), do: SurrealStore.get(User, id)"
      assert body =~ "def create_user(attrs), do: SurrealStore.create(User, attrs)"
      assert body =~ "def update_user(id, attrs), do: SurrealStore.update(User, id, attrs)"
      assert body =~ "def delete_user(id), do: SurrealStore.delete(User, id)"
    end
  end
end
