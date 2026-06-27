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
end
