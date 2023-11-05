defmodule DemoWeb.FileController do
  use DemoWeb, :controller

  def show(conn, %{"doc" => doc, "filename" => filename}) do
    valid = Regex.match?(~r/^[^\/\\]+$/, filename)
    file_path = Path.join(:code.priv_dir(:demo), "/pdf/#{doc}/#{filename}")

    if valid && File.exists?(file_path) do
      conn
      |> put_resp_content_type(content_type_for_file(file_path))
      |> send_file(200, file_path)
    else
      send_resp(conn, 404, "File not found")
    end
  end

  @doc false
  def content_type_for_file(path) do
    case Path.extname(path) do
      ".png" -> "image/png"
      _ -> "application/octet-stream"
    end
  end
end
