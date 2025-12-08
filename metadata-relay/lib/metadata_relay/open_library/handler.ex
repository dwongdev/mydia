defmodule MetadataRelay.OpenLibrary.Handler do
  @moduledoc """
  HTTP request handlers for Open Library API endpoints.
  """

  alias MetadataRelay.OpenLibrary.Client

  @doc """
  GET /openlibrary/isbn/:isbn
  Lookup book by ISBN.
  """
  def get_by_isbn(isbn, _params) do
    # Open Library Books API
    # https://openlibrary.org/dev/docs/api/books
    Client.get("/api/books", params: [bibkeys: "ISBN:#{isbn}", jscmd: "data", format: "json"])
  end

  @doc """
  GET /openlibrary/search
  Search for books by title or author.
  Supported params: q, title, author
  """
  def search(params) do
    # Open Library Search API
    # https://openlibrary.org/dev/docs/api/search
    Client.get("/search.json", params: params)
  end

  @doc """
  GET /openlibrary/works/:olid
  Get work details by Open Library ID (OLID).
  """
  def get_work(olid, _params) do
    Client.get("/works/#{olid}.json")
  end

  @doc """
  GET /openlibrary/authors/:olid
  Get author details by Open Library ID (OLID).
  """
  def get_author(olid, _params) do
    Client.get("/authors/#{olid}.json")
  end
end
