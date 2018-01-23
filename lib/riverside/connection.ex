defmodule Riverside.Connection do

  @behaviour :cowboy_websocket_handler

  require Logger

  alias Riverside.LocalDelivery
  alias Riverside.PeerAddress
  alias Riverside.Session
  alias Riverside.Stats

  @type shutdown_reason :: :too_many_messages

  @type t :: %__MODULE__{handler:         module,
                         session:         Session.t,
                         shutdown_reason: shutdown_reason,
                         handler_state:   any}

  defstruct handler:         nil,
            session:         nil,
            shutdown_reason: nil,
            handler_state:   nil

  def new(handler, user_id, peer, handler_state) do
    %__MODULE__{handler:         handler,
                session:         Session.new(user_id, peer),
                shutdown_reason: nil,
                handler_state:   handler_state}
  end

  def init(_, req, opts) do

    peer = PeerAddress.gather(req)

    Logger.debug "<Riverside.Connection> incoming new request: #{peer}"

    handler = Keyword.fetch!(opts, :handler)

    if Stats.number_of_current_connections() >= handler.__max_connections__() do

      Logger.info "<Riverside.Connection> connection number is over limit"

      {:shutdown, req, nil}

    else

      case handler.__handle_authentication__(req, peer) do

        {:ok, user_id, handler_state} ->
          state = new(handler, user_id, peer, handler_state)
          {:upgrade, :protocol, :cowboy_websocket, req, state}

        {:error, reason, req2} ->
          Logger.debug "<Riverside.Connection> failed to authenticate by reason: #{reason}, shutdown"
          {:shutdown, req2, nil}

      end

    end

  end

  def terminate(_reason, _req, _state) do
    :ok
  end

  def websocket_init(_type, req, state) do

    Logger.debug "<Riverside.#{state.session}> @init"

    if Stats.number_of_current_connections() >= state.handler.__max_connections__() do

      Logger.info "<Riverside.Connection> connection number is over limit"

      {:shutdown, req}

    else

      Process.flag(:trap_exit, true)

      send self(), :post_init

      Stats.countup_connections()

      LocalDelivery.register(state.session.user_id, state.session.id)

      timeout = state.handler.__connection_timeout__

      {:ok, :cowboy_req.compact(req), state, timeout, :hibernate}

    end


  end

  def websocket_info(:post_init, req, state) do

    Logger.debug "<Riverside.#{state.session}> @post_init"

    case state.handler.init(state.session, state.handler_state) do

      {:ok, session2, handler_state2} ->
        state2 = %{state| session: session2, handler_state: handler_state2}
        {:ok, req, state2, :hibernate}

      {:error, reason} ->
        Logger.info "<Riverside.#{state.session}> failed to initialize: #{inspect reason}"
        {:shutdown, req, state}

    end

  end

  def websocket_info(:stop, req, state) do

    Logger.debug "<Riverside.#{state.session}> @stop"

    {:shutdown, req, state}
  end

  def websocket_info({:deliver, type, msg}, req, state) do

    Logger.debug "<Riverside.#{state.session}> @deliver"

    Stats.countup_outgoing_messages()

    {:reply, {type, msg}, req, state, :hibernate}
  end

  def websocket_info({:EXIT, pid, reason}, req, %{session: session}=state) do

    Logger.debug "<Riverside.#{session}> @exit: #{inspect pid} -> #{inspect self()}"

    if Session.should_delegate_exit?(session, pid) do

      session2 = Session.forget_to_trap_exit(session, pid)

      state2 = %{state| session: session2}

      handler_info({:EXIT, pid, reason}, req, state2)

    else

      {:shutdown, req, state}

    end

  end

  def websocket_info(event, req, state) do

    Logger.debug "<Riverside.#{state.session}> @info: #{inspect event}"

    handler_info(event, req, state)

  end

  defp handler_info(event, req, state) do

    case state.handler.handle_info(event, state.session, state.handler_state) do

      {:ok, session2, handler_state2} ->
        state2 = %{state| session: session2, handler_state: handler_state2}
        {:ok, req, state2}

      # TODO support reply?
      _other ->
        {:shutdown, req, state}
    end

  end

  def websocket_handle({:ping, data}, req, state) do

    Logger.debug "<Riverside.#{state.session}> @ping"

    handle_frame(req, :ping, data, state)

  end

  def websocket_handle({:binary, data}, req, state) do

    Logger.debug "<Riverside.#{state.session}> @binary"

    handle_frame(req, :binary, data, state)

  end

  def websocket_handle({:text, data}, req, state) do

    Logger.debug "<Riverside.#{state.session}> @text"

    handle_frame(req, :text, data, state)

  end

  def websocket_handle(event, req, state) do

    Logger.debug "<Riverside.#{state.session}> handle: unsupported event #{inspect event}"

    {:ok, req, state}

  end

  def websocket_terminate(reason, _req, %{shutdown_reason: nil}=state) do

    Logger.info "<Riverside.#{state.session}> @terminate: #{inspect reason}"

    state.handler.terminate(reason, state.session, state.handler_state)

    Stats.countdown_connections()

    :ok
  end
  def websocket_terminate(reason, _req, state) do

    Logger.info "<Riverside.#{state.session}> @terminate: #{inspect reason}"

    state.handler.terminate(state.shutdown_reason, state.session, state.handler_state)

    Stats.countdown_connections()

    :ok
  end

  defp handle_frame(req, type, data, %{handler: handler, session: session}=state) do

    Stats.countup_incoming_messages()

    case Session.countup_messages(session, handler.__transmission_limit__) do

      {:ok, session2} ->
        state2 = %{state| session: session2}
        case handle_data(type, data, state2) do

          {:ok, session3, handler_state3} ->
            state3 = %{state2| session: session3, handler_state: handler_state3}
            {:ok, req, state3, :hibernate}

          {:error, reason} ->
            Logger.info "<Riverside.#{session2}> failed to handle frame_type #{inspect type}: #{inspect reason}"
            {:ok, req, state2}

        end

      {:error, :too_many_messages} ->
        Logger.warn "<Riverside.#{session}> too many messages: #{Session.peer_address(session)}"
        {:shutdown, req, %{state| shutdown_reason: :too_many_messages}}

    end

  end

  defp handle_data(:text, data, state) do
    state.handler.__handle_data__(:text, data, state.session, state.handler_state)
  end
  defp handle_data(:binary, data, state) do
    state.handler.__handle_data__(:binary, data, state.session, state.handler_state)
  end
  defp handle_data(:ping, _data, state) do
    {:ok, state.session, state.handler_state}
  end

end
