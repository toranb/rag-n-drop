defmodule DemoWeb.PageLive do
  use DemoWeb, :live_view

  alias Demo.Repo

  @impl true
  def mount(_, _, socket) do
    messages = []
    model = Replicate.Models.get!("meta/llama-2-7b-chat")
    version = Replicate.Models.get_latest_version!(model)
    documents = Demo.Document |> Repo.all() |> Repo.preload(:sections)

    socket =
      socket
      |> assign(task: nil, lookup: nil, filename: nil, messages: messages, version: version, documents: documents, result: nil, text: nil, loading: false, selected: nil, query: nil, transformer: nil, llama: nil, path: nil, focused: false, loadingpdf: false)
      |> allow_upload(:document, accept: ~w(.pdf), progress: &handle_progress/3, auto_upload: true, max_entries: 1)

    {:ok, socket}
  end

  @impl true
  def handle_event("dragged", %{"focused" => focused}, socket) do
    {:noreply, assign(socket, focused: focused)}
  end

  @impl true
  def handle_event("select_document", %{"id" => document_id}, socket) do
    document = socket.assigns.documents |> Enum.find(&(&1.id == String.to_integer(document_id)))
    socket = socket |> assign(selected: document, result: nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("change_text", %{"message" => text}, socket) do
    socket = socket |> assign(text: text)

    {:noreply, socket}
  end

  @impl true
  def handle_event("add_message", _, %{assigns: %{loadingpdf: true}} = socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("add_message", _, %{assigns: %{loading: true}} = socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("add_message", %{"message" => ""}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("add_message", %{"message" => question}, socket) do
    selected = socket.assigns.selected
    message_id = Ecto.UUID.generate()

    lookup =
      Task.async(fn ->
        {selected, question, Nx.Serving.batched_run(SentenceTransformer, question)}
      end)

    messages = socket.assigns.messages
    new_messages = messages ++ [%{id: message_id, user_id: 1, text: question, url: nil, inserted_at: DateTime.utc_now(), document_id: selected.id}]

    {:noreply, assign(socket, lookup: lookup, messages: new_messages, loading: true, text: nil)}
  end

  @impl true
  def handle_info({ref, {selected, question, %{embedding: embedding}}}, socket) when socket.assigns.lookup.ref == ref do
    version = socket.assigns.version

    section = Demo.Section.search_document(selected.id, embedding)
    document = socket.assigns.documents |> Enum.find(&(&1.id == section.document_id))

    prompt = """
    [INST] <<SYS>>
    You are an assistant for question-answering tasks. Use the following pieces of retrieved context to answer the question.
    If you do not know the answer, just say that you don't know. Use two sentences maximum and keep the answer concise.
    <</SYS>>
    Question: #{question}
    Context: #{section.text}[/INST]
    """

    llama =
      Task.async(fn ->
        {:ok, prediction} = Replicate.Predictions.create(version, %{prompt: prompt})
        {section, Replicate.Predictions.wait(prediction)}
      end)

    {:noreply, assign(socket, lookup: nil, llama: llama, selected: document)}
  end

  @impl true
  def handle_info({ref, {section, {:ok, prediction}}}, socket) when socket.assigns.llama.ref == ref do
    message_id = Ecto.UUID.generate()
    image_id = Ecto.UUID.generate()

    messages = socket.assigns.messages
    selected = socket.assigns.selected

    text = Enum.join(prediction.output) <> " You can find more details on page #{section.page}."
    previous = Demo.Section |> Demo.Repo.get_by!(document_id: section.document_id, page: section.page - 1)

    now = DateTime.utc_now()
    message = %{id: message_id, document_id: selected.id, user_id: nil, text: text, url: nil, inserted_at: now}
    image = %{id: image_id, document_id: selected.id, user_id: nil, text: nil, url: previous.filepath, inserted_at: now}
    new_messages = messages ++ [message, image]

    {:noreply, assign(socket, llama: nil, loading: false, messages: new_messages)}
  end

  @impl true
  def handle_info({ref, results}, socket) when socket.assigns.task.ref == ref do
    filename = socket.assigns.filename

    document =
      %Demo.Document{}
      |> Demo.Document.changeset(%{title: filename, machine: "test"})
      |> Repo.insert!()

    results
    |> Enum.reject(fn {text, _filepath, _embedding} -> text == "" end)
    |> Enum.each(fn {text, filepath, embedding} ->
      page = Regex.replace(~r/(?<p>)^(.*-)/, filepath, "\\1") |> String.replace(".png", "")
      %Demo.Section{}
      |> Demo.Section.changeset(%{filepath: filepath, page: page, text: text, document_id: document.id, embedding: embedding})
      |> Repo.insert!()
    end)

    documents = Demo.Document |> Repo.all() |> Repo.preload(:sections)
    socket = socket |> assign(documents: documents, selected: document, loadingpdf: false, task: nil, filename: nil)

    {:noreply, socket}
  end

  @impl true
  def handle_info({ref, {directory, {"", 0}}}, socket) when socket.assigns.query.ref == ref do
    task =
      document_embeddings(directory, fn text, filepath, embedding ->
        {text, filepath, embedding}
      end)

    {:noreply, assign(socket, query: nil, task: task)}
  end

  @impl true
  def handle_info({ref, {_directory, _result}}, socket) when socket.assigns.query.ref == ref do
    {:noreply, socket}
  end

  @impl true
  def handle_info({ref, {section, %{embedding: embedding}}}, socket) when socket.assigns.transformer.ref == ref do
    Demo.Section
    |> Repo.get!(section.id)
    |> Demo.Section.changeset(%{embedding: embedding})
    |> Repo.update!()

    document = socket.assigns.documents |> Enum.find(&(&1.id == section.document_id))
    socket = socket |> assign(transformer: nil, selected: document, loadingpdf: false)

    {:noreply, socket}
  end

  @impl true
  def handle_info(_, socket) do
    {:noreply, socket}
  end

  def handle_progress(:document, %{client_name: filename} = entry, socket) when entry.done? do
    path =
      consume_uploaded_entries(socket, :document, fn %{path: path}, _entry ->
        dest = Path.join(["priv", "static", "uploads", Path.basename("#{path}/#{filename}")])
        File.cp!(path, dest)
        {:ok, dest}
      end)
      |> List.first()

    id = :rand.uniform(1000)
    directory = "priv/pdf/#{id}"
    File.mkdir_p!(directory)

    query =
      Task.async(fn ->
        {directory, System.cmd("pdftoppm", [path, "#{directory}/image", "-png"])}
      end)

    {:noreply, assign(socket, path: path, query: query, filename: filename, loadingpdf: true)}
  end

  def handle_progress(_name, _entry, socket), do: {:noreply, socket}

  def document_embeddings(directory, func) do
    Task.async(fn ->
      Path.wildcard("#{directory}/*.png")
      |> Task.async_stream(fn filepath ->
        System.cmd("tesseract", [filepath] ++ ~w(stdout))
        |> case do
          {"", 0} ->
            {"", filepath, %{embedding: []}}

          {text, 0} ->
            {text, filepath, Nx.Serving.batched_run(SentenceTransformer, text)}

          _ ->
            {"", filepath, %{embedding: []}}
        end
        end,
        max_concurrency: 4,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, {text, filepath, %{embedding: embedding}}} ->
        func.(text, filepath, embedding)
      end)
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col grow px-2 sm:px-4 lg:px-8 py-10">
      <div class="flex flex-col grow relative -mb-8 mt-2 mt-2">
        <div class="absolute inset-0 gap-4">
          <div class="h-full flex flex-col bg-white shadow-sm border rounded-md">
            <div class="grid-cols-4 h-full grid divide-x">
              <div :if={!Enum.empty?(@documents)} class="flex flex-col hover:scroll-auto">
                <div class="flex flex-col justify-stretch grow p-2">
                  <%= for document <- @documents do %>
                  <div id={"doc-#{document.id}"} class="flex flex-col justify-stretch">
                    <button type="button" phx-click="select_document" phx-value-id={document.id} class={"flex p-4 items-center justify-between rounded-md hover:bg-gray-100 text-sm text-left text-gray-700 outline-none #{if @selected && @selected.id == document.id, do: "bg-gray-100"}"}>
                      <div class="flex flex-col overflow-hidden">
                        <div class="inline-flex items-center space-x-1 font-medium text-sm text-gray-800">
                          <div class="p-1 rounded-full bg-gray-200 text-gray-900">
                            <div class="rounded-full w-9 h-9 min-w-9 flex justify-center items-center text-base bg-purple-600 text-white capitalize"><%= String.first(document.title) %></div>
                          </div>
                          <span class="pl-1 capitalize"><%= document.title %></span>
                        </div>
                        <div class="hidden mt-1 inline-flex justify-start items-center flex-nowrap text-xs text-gray-500 overflow-hidden">
                          <span class="whitespace-nowrap text-ellipsis overflow-hidden"><%= document.title %></span>
                          <span class="mx-1 inline-flex rounded-full w-0.5 h-0.5 min-w-0.5 bg-gray-500"></span>
                        </div>
                      </div>
                    </button>
                  </div>
                  <% end %>
                </div>
              </div>
              <div class={"block relative #{if Enum.empty?(@documents), do: "col-span-4", else: "col-span-3"}"}>
                <div class="flex absolute inset-0 flex-col">
                  <div class="relative flex grow overflow-y-hidden">
                    <div :if={!is_nil(@selected)} class="pt-4 pb-1 px-4 flex flex-col grow overflow-y-auto">
                      <%= for message <- Enum.filter(@messages, fn m -> m.document_id == @selected.id end) do %>
                      <div :if={message.user_id != 1} class="my-2 flex flex-row justify-start space-x-1 self-start items-start">
                        <div :if={!is_nil(message.url)} class="flex flex-col space-y-0.5 self-start items-start">
                          <a class="inline-flex self-start items-start" href={"/#{message.url}"} target="_blank" rel="noreferrer"><img class="rounded-lg max-w-44 xs:max-w-56 sm:max-w-72 max-h-52" src={"/#{message.url}"} alt="photo"></a>
                          <div class="mx-1 text-xs text-gray-500"><%= Calendar.strftime(message.inserted_at, "%B %d, %-I:%M %p") %></div>
                        </div>
                        <div :if={is_nil(message.url)} class="flex flex-col space-y-0.5 self-start items-start">
                          <div class="bg-gray-200 text-gray-900 ml-0 mr-12 py-2 px-3 inline-flex text-sm rounded-lg whitespace-pre-wrap"><%= message.text %></div>
                          <div class="mx-1 text-xs text-gray-500"><%= Calendar.strftime(message.inserted_at, "%B %d, %-I:%M %p") %></div>
                        </div>
                      </div>
                      <div :if={message.user_id == 1} class="my-2 flex flex-row justify-start space-x-1 self-end items-end">
                        <div class="flex flex-col space-y-0.5 self-end items-end">
                          <div class="bg-purple-600 text-gray-50 ml-12 mr-0 py-2 px-3 inline-flex text-sm rounded-lg whitespace-pre-wrap"><%= message.text %></div>
                          <div class="mx-1 text-xs text-gray-500"><%= Calendar.strftime(message.inserted_at, "%B %d, %-I:%M %p") %></div>
                        </div>
                      </div>
                      <% end %>
                      <div :if={@loading} class="typing"><div class="typing__dot"></div><div class="typing__dot"></div><div class="typing__dot"></div></div>
                    </div>
                  </div>
                  <form class="px-4 py-2 flex flex-row items-end gap-x-2" phx-submit="add_message" phx-change="change_text" phx-drop-target={@uploads.document.ref}>
                    <.live_file_input class="sr-only" upload={@uploads.document} />
                    <div id="dragme" phx-hook="Drag" class={"flex flex-col grow rounded-md #{if !is_nil(@path), do: "border"} #{if @focused, do: "ring-1 border-indigo-500 ring-indigo-500 border"}"}>
                      <div :if={!is_nil(@path)} class="mx-2 mt-3 mb-2 flex flex-row items-center rounded-md gap-x-4 gap-y-3 flex-wrap">
                        <div class="relative">
                          <div class="px-2 h-14 min-w-14 min-h-14 inline-flex items-center gap-x-2 text-sm rounded-lg whitespace-pre-wrap bg-gray-200 text-gray-900 bg-gray-200 text-gray-900 max-w-24 sm:max-w-32">
                            <div class="p-2 inline-flex justify-center items-center rounded-full bg-gray-300 text-gray-900 bg-gray-300 text-gray-900">
                              <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" aria-hidden="true" class="w-5 h-5">
                                <path fill-rule="evenodd" d="M4 4a2 2 0 012-2h4.586A2 2 0 0112 2.586L15.414 6A2 2 0 0116 7.414V16a2 2 0 01-2 2H6a2 2 0 01-2-2V4zm2 6a1 1 0 011-1h6a1 1 0 110 2H7a1 1 0 01-1-1zm1 3a1 1 0 100 2h6a1 1 0 100-2H7z" clip-rule="evenodd"></path>
                              </svg>
                            </div>
                            <span class="truncate"><%= String.split(@path, "/") |> List.last() %></span>
                          </div>
                          <div :if={@loadingpdf} class="flex p-1 absolute -top-2 -right-2 rounded-full bg-gray-100 hover:bg-gray-200 text-gray-500 border border-gray-300 shadow">
                            <div class="text-gray-700 inline-block h-4 w-4 animate-spin rounded-full border-2 border-solid border-current border-r-transparent motion-reduce:animate-[spin_1.5s_linear_infinite]" role="status">
                              <span class="!absolute !-m-px !h-px !w-px !overflow-hidden !whitespace-nowrap !border-0 !p-0 ![clip:rect(0,0,0,0)]">Loading...</span>
                            </div>
                          </div>
                        </div>
                      </div>
                      <div class="relative flex grow">
                        <input id="message" name="message" value={@text} class={"#{if !is_nil(@path), do: "border-transparent"} block w-full rounded-md border-gray-300 shadow-sm #{if is_nil(@path), do: "focus:border-indigo-500 focus:ring-indigo-500"} text-sm placeholder:text-gray-400 text-gray-900"} placeholder={if is_nil(@path), do: "drag pdf here to get started", else: "Ask a question..."} type="text" />
                      </div>
                    </div>
                    <div class="ml-1">
                        <button disabled={is_nil(@path) && !@selected} type="submit" class={"flex items-center justify-center h-10 w-10 rounded-full #{if is_nil(@path) && !@selected, do: "cursor-not-allowed bg-gray-100 text-gray-300", else: "hover:bg-gray-300 bg-gray-200 text-gray-500"}"}>
                        <svg class="w-5 h-5 transform rotate-90 -mr-px" fill="none" stroke="currentColor" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
                          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 19l9 2-9-18-9 18 9-2zm0 0v-8"></path>
                        </svg>
                      </button>
                    </div>
                  </form>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
