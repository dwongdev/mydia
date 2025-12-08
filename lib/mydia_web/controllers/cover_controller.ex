defmodule MydiaWeb.CoverController do
  use MydiaWeb, :controller

  alias Mydia.Music
  alias Mydia.Library.GeneratedMedia

  def show(conn, %{"id" => id}) do
    album = Music.get_album!(id)
    serve_cover(conn, album)
  rescue
    Ecto.NoResultsError -> send_resp(conn, 404, "Album not found")
  end

  defp serve_cover(conn, album) do
    if album.cover_blob do
      path = GeneratedMedia.get_path(:cover, album.cover_blob)

      if File.exists?(path) do
        conn
        |> put_resp_header("cache-control", "public, max-age=31536000")
        |> put_resp_content_type("image/jpeg")
        |> send_file(200, path)
      else
        send_resp(conn, 404, "Cover file missing")
      end
    else
      # TODO: Serve placeholder
      send_resp(conn, 404, "No cover art")
    end
  end
end
