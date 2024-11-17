defmodule BibTest do
  use ExUnit.Case
  doctest Bib

  test "greets the world" do
    assert Bib.hello() == :world
  end
end
