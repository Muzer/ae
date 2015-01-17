﻿/**
 * Asynchronous socket abstraction.
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Stéphan Kochen <stephan@kochen.nl>
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 *   Vincent Povirk <madewokherd@gmail.com>
 *   Simon Arlott
 */

module ae.net.asockets;

import ae.sys.timing;
import ae.utils.math;
public import ae.sys.data;

import std.exception;
import std.socket;
public import std.socket : Address, Socket;

debug(ASOCKETS) import std.stdio;
debug(PRINTDATA) import ae.utils.text : hexDump;
private import std.conv : to;


// http://d.puremagic.com/issues/show_bug.cgi?id=7016
static import ae.utils.array;

version(LIBEV)
{
	import deimos.ev;
	pragma(lib, "ev");
}

version(Windows)
{
	import core.sys.windows.windows : Sleep;
	enum USE_SLEEP = true; // avoid convoluted mix of static and runtime conditions
}
else
	enum USE_SLEEP = false;

/// Flags that determine socket wake-up events.
int eventCounter;

version(LIBEV)
{
	// Watchers are a GenericSocket field (as declared in SocketMixin).
	// Use one watcher per read and write event.
	// Start/stop those as higher-level code declares interest in those events.
	// Use the "data" ev_io field to store the parent GenericSocket address.
	// Also use the "data" field as a flag to indicate whether the watcher is active
	// (data is null when the watcher is stopped).

	struct SocketManager
	{
	private:
		size_t count;

		extern(C)
		static void ioCallback(ev_loop_t* l, ev_io* w, int revents)
		{
			eventCounter++;
			auto socket = cast(GenericSocket)w.data;
			assert(socket, "libev event fired on stopped watcher");
			debug (ASOCKETS) writefln("ioCallback(%s, 0x%X)", cast(void*)socket, revents);

			if (revents & EV_READ)
				socket.onReadable();
			else
			if (revents & EV_WRITE)
				socket.onWritable();
			else
				assert(false, "Unknown event fired from libev");

			// TODO? Need to get proper SocketManager instance to call updateTimer on
			socketManager.updateTimer(false);
		}

		ev_timer evTimer;
		MonoTime lastNextEvent = MonoTime.max;

		extern(C)
		static void timerCallback(ev_loop_t* l, ev_timer* w, int revents)
		{
			eventCounter++;
			debug (ASOCKETS) writefln("Timer callback called.");
			mainTimer.prod();

			socketManager.updateTimer(true);
			debug (ASOCKETS) writefln("Timer callback exiting.");
		}

		void updateTimer(bool force)
		{
			auto nextEvent = mainTimer.getNextEvent();
			if (force || lastNextEvent != nextEvent)
			{
				debug (ASOCKETS) writefln("Rescheduling timer. Was at %s, now at %s", lastNextEvent, nextEvent);
				if (nextEvent == MonoTime.max) // Stopping
				{
					if (lastNextEvent != MonoTime.max)
						ev_timer_stop(ev_default_loop(0), &evTimer);
				}
				else
				{
					auto remaining = mainTimer.getRemainingTime();
					while (remaining <= Duration.zero)
					{
						debug (ASOCKETS) writefln("remaining=%s, prodding timer.", remaining);
						mainTimer.prod();
						remaining = mainTimer.getRemainingTime();
					}
					ev_tstamp tstamp = remaining.total!"hnsecs" * 1.0 / convert!("seconds", "hnsecs")(1);
					debug (ASOCKETS) writefln("remaining=%s, ev_tstamp=%s", remaining, tstamp);
					if (lastNextEvent == MonoTime.max) // Starting
					{
						ev_timer_init(&evTimer, &timerCallback, 0., tstamp);
						ev_timer_start(ev_default_loop(0), &evTimer);
					}
					else // Adjusting
					{
						evTimer.repeat = tstamp;
						ev_timer_again(ev_default_loop(0), &evTimer);
					}
				}
				lastNextEvent = nextEvent;
			}
		}

		/// Register a socket with the manager.
		void register(GenericSocket socket)
		{
			debug (ASOCKETS) writefln("Registering %s", cast(void*)socket);
			debug assert(socket.evRead.data is null && socket.evWrite.data is null, "Re-registering a started socket");
			auto fd = socket.conn.handle;
			assert(fd, "Must have fd before socket registration");
			ev_io_init(&socket.evRead , &ioCallback, fd, EV_READ );
			ev_io_init(&socket.evWrite, &ioCallback, fd, EV_WRITE);
			count++;
		}

		/// Unregister a socket with the manager.
		void unregister(GenericSocket socket)
		{
			debug (ASOCKETS) writefln("Unregistering %s", cast(void*)socket);
			socket.notifyRead  = false;
			socket.notifyWrite = false;
			count--;
		}

	public:
		size_t size()
		{
			return count;
		}

		/// Loop continuously until no sockets are left.
		void loop()
		{
			auto evLoop = ev_default_loop(0);
			enforce(evLoop, "libev initialization failure");

			updateTimer(true);
			debug (ASOCKETS) writeln("ev_run");
			ev_run(ev_default_loop(0), 0);
		}
	}

	private mixin template SocketMixin()
	{
		private ev_io evRead, evWrite;

		private void setWatcherState(ref ev_io ev, bool newValue, int event)
		{
			if (!conn)
			{
				// Can happen when setting delegates before connecting.
				return;
			}

			if (newValue && !ev.data)
			{
				// Start
				ev.data = cast(void*)this;
				ev_io_start(ev_default_loop(0), &ev);
			}
			else
			if (!newValue && ev.data)
			{
				// Stop
				assert(ev.data is cast(void*)this);
				ev.data = null;
				ev_io_stop(ev_default_loop(0), &ev);
			}
		}

		/// Interested in read notifications (onReadable)?
		@property final void notifyRead (bool value) { setWatcherState(evRead , value, EV_READ ); }
		/// Interested in write notifications (onWritable)?
		@property final void notifyWrite(bool value) { setWatcherState(evWrite, value, EV_WRITE); }

		debug ~this()
		{
			// The LIBEV SocketManager holds no references to registered sockets.
			// TODO: Add a doubly-linked list?
			assert(evRead.data is null && evWrite.data is null, "Destroying a registered socket");
		}
	}
}
else // Use select
{
	struct SocketManager
	{
	private:
		enum FD_SETSIZE = 1024;

		/// List of all sockets to poll.
		GenericSocket[] sockets;

		/// Register a socket with the manager.
		void register(GenericSocket conn)
		{
			debug (ASOCKETS) writefln("Registering %s (%d total)", cast(void*)conn, sockets.length + 1);
			assert(!conn.socket.blocking, "Trying to register a blocking socket");
			sockets ~= conn;
		}

		/// Unregister a socket with the manager.
		void unregister(GenericSocket conn)
		{
			debug (ASOCKETS) writefln("Unregistering %s (%d total)", cast(void*)conn, sockets.length - 1);
			foreach (size_t i, GenericSocket j; sockets)
				if (j is conn)
				{
					sockets = sockets[0 .. i] ~ sockets[i + 1 .. sockets.length];
					return;
				}
			assert(false, "Socket not registered");
		}

		void delegate()[] idleHandlers;

	public:
		size_t size()
		{
			return sockets.length;
		}

		/// Loop continuously until no sockets are left.
		void loop()
		{
			debug (ASOCKETS) writeln("Starting event loop.");

			SocketSet readset, writeset, errorset;
			size_t sockcount;
			readset  = new SocketSet(FD_SETSIZE);
			writeset = new SocketSet(FD_SETSIZE);
			errorset = new SocketSet(FD_SETSIZE);
			while (true)
			{
				// SocketSet.add() doesn't have an overflow check, so we need to do it manually
				// this is just a debug check, the actual check is done when registering sockets
				// TODO: this is inaccurate on POSIX, "max" means maximum fd value
				if (sockets.length > readset.max || sockets.length > writeset.max || sockets.length > errorset.max)
				{
					readset  = new SocketSet(to!uint(sockets.length*2));
					writeset = new SocketSet(to!uint(sockets.length*2));
					errorset = new SocketSet(to!uint(sockets.length*2));
				}
				else
				{
					readset.reset();
					writeset.reset();
					errorset.reset();
				}

				sockcount = 0;
				bool haveActive;
				debug (ASOCKETS) writeln("Populating sets");
				foreach (GenericSocket conn; sockets)
				{
					if (!conn.socket)
						continue;
					sockcount++;
					if (!conn.daemon)
						haveActive = true;

					debug (ASOCKETS) writef("\t%s:", cast(void*)conn);
					if (conn.notifyRead)
					{
						readset.add(conn.socket);
						debug (ASOCKETS) write(" READ");
					}
					if (conn.notifyWrite)
					{
						writeset.add(conn.socket);
						debug (ASOCKETS) write(" WRITE");
					}
					errorset.add(conn.socket);
					debug (ASOCKETS) writeln();
				}
				debug (ASOCKETS) writefln("Waiting (%d sockets, %s timer events, %d idle handlers)...",
					sockcount,
					mainTimer.isWaiting() ? "with" : "no",
					idleHandlers.length,
				);
				if (!haveActive && !mainTimer.isWaiting())
				{
					debug (ASOCKETS) writeln("No more sockets or timer events, exiting loop.");
					break;
				}

				int events;
				if (idleHandlers.length)
				{
					if (sockcount==0)
						events = 0;
					else
						events = Socket.select(readset, writeset, errorset, 0.seconds);
				}
				else
				if (USE_SLEEP && sockcount==0)
				{
					version(Windows)
					{
						auto duration = mainTimer.getRemainingTime().total!"msecs"();
						debug (ASOCKETS) writeln("Wait duration: ", duration, " msecs");
						if (duration <= 0)
							duration = 1; // Avoid busywait
						else
						if (duration > int.max)
							duration = int.max;
						Sleep(cast(int)duration);
						events = 0;
					}
					else
						assert(0);
				}
				else
				if (mainTimer.isWaiting())
					events = Socket.select(readset, writeset, errorset, mainTimer.getRemainingTime());
				else
					events = Socket.select(readset, writeset, errorset);

				debug (ASOCKETS) writefln("%d events fired.", events);

				if (events > 0)
				{
					// Handle just one event at a time, as the first
					// handler might invalidate select()'s results.
					handleEvent(readset, writeset, errorset);
				}
				else
				if (idleHandlers.length)
				{
					import ae.utils.array;
					auto handler = idleHandlers.shift();

					// Rotate the idle handler queue before running it,
					// in case the handler unregisters itself.
					idleHandlers ~= handler;

					handler();
				}

				// Timers may invalidate our select results, so fire them after processing the latter
				mainTimer.prod();

				eventCounter++;
			}
		}

		void handleEvent(SocketSet readset, SocketSet writeset, SocketSet errorset)
		{
			foreach (GenericSocket conn; sockets)
			{
				if (!conn.socket)
				{
					debug (ASOCKETS) writefln("\t%s is unset", cast(void*)conn);
					continue;
				}

				if (readset.isSet(conn.socket))
				{
					debug (ASOCKETS) writefln("\t%s is readable", cast(void*)conn);
					return conn.onReadable();
				}
				else
				if (writeset.isSet(conn.socket))
				{
					debug (ASOCKETS) writefln("\t%s is writable", cast(void*)conn);
					return conn.onWritable();
				}
				else
				if (errorset.isSet(conn.socket))
				{
					debug (ASOCKETS) writefln("\t%s is errored", cast(void*)conn);
					return conn.onError("select() error: " ~ conn.socket.getErrorText());
				}
			}

			assert(false, "select() reported events available, but no registered sockets are set");
		}
	}

	// Use UFCS to allow removeIdleHandler to have a predicate with context
	void addIdleHandler(ref SocketManager socketManager, void delegate() handler)
	{
		foreach (i, idleHandler; socketManager.idleHandlers)
			assert(handler !is idleHandler);

		socketManager.idleHandlers ~= handler;
	}

	static bool isFun(T)(T a, T b) { return a is b; }
	void removeIdleHandler(alias pred=isFun, Args...)(ref SocketManager socketManager, Args args)
	{
		foreach (i, idleHandler; socketManager.idleHandlers)
			if (pred(idleHandler, args))
			{
				import std.algorithm;
				socketManager.idleHandlers = socketManager.idleHandlers.remove(i);
				return;
			}
		assert(false, "No such idle handler");
	}

	private mixin template SocketMixin()
	{
		/// Interested in read notifications (onReadable)?
		bool notifyRead;
		/// Interested in write notifications (onWritable)?
		bool notifyWrite;
	}
}

/// The default socket manager.
SocketManager socketManager;

// ***************************************************************************

/// General methods for an asynchronous socket.
private abstract class GenericSocket
{
	/// Declares notifyRead and notifyWrite.
	mixin SocketMixin;

protected:
	/// The socket this class wraps.
	Socket conn;

protected:
	/// Retrieve the socket class this class wraps.
	@property final Socket socket()
	{
		return conn;
	}

	void onReadable()
	{
	}

	void onWritable()
	{
	}

	void onError(string reason)
	{
	}

public:
	/// allow getting the address of connections that are already disconnected
	private Address cachedLocalAddress, cachedRemoteAddress;

	/// Don't block the process from exiting.
	/// TODO: Not implemented with libev
	bool daemon;

	final @property Address localAddress()
	{
		if (cachedLocalAddress !is null)
			return cachedLocalAddress;
		else
		if (conn is null)
			return null;
		else
			return cachedLocalAddress = conn.localAddress();
	}

	final @property Address remoteAddress()
	{
		if (cachedRemoteAddress !is null)
			return cachedRemoteAddress;
		else
		if (conn is null)
			return null;
		else
			return cachedRemoteAddress = conn.remoteAddress();
	}

	final void setKeepAlive(bool enabled=true, int time=10, int interval=5)
	{
		assert(conn, "Attempting to set keep-alive on an uninitialized socket");
		if (enabled)
		{
			try
				conn.setKeepAlive(time, interval);
			catch (SocketFeatureException)
				conn.setOption(SocketOptionLevel.SOCKET, SocketOption.KEEPALIVE, true);
		}
		else
			conn.setOption(SocketOptionLevel.SOCKET, SocketOption.KEEPALIVE, false);
	}
}

// ***************************************************************************

enum DisconnectType
{
	requested, // initiated by the application
	graceful,  // peer gracefully closed the connection
	error      // abnormal network condition
}

/// Common interface for connections and adapters.
interface IConnection
{
	enum MAX_PRIORITY = 4;
	enum DEFAULT_PRIORITY = 2;

	static const defaultDisconnectReason = "Software closed the connection";

	/// Has a connection been established?
	@property bool connected();

	/// Are we in the process of disconnecting? (Waiting for data to be flushed)
	@property bool disconnecting();

	/// Queue Data for sending.
	void send(Data[] data, int priority = DEFAULT_PRIORITY);

	/// ditto
	final void send(Data datum, int priority = DEFAULT_PRIORITY)
	{
		Data[1] data;
		data[0] = datum;
		this.send(data);
		data[] = Data.init;
	}

	/// Terminate the connection.
	void disconnect(string reason = defaultDisconnectReason, DisconnectType type = DisconnectType.requested);

	/// Callback setter for when a connection has been established
	/// (if applicable).
	alias void delegate() ConnectHandler;
	@property void handleConnect(ConnectHandler value); /// ditto

	/// Callback setter for when new data is read.
	alias void delegate(Data data) ReadDataHandler;
	@property void handleReadData(ReadDataHandler value); /// ditto

	/// Callback setter for when a connection was closed.
	alias void delegate(string reason, DisconnectType type) DisconnectHandler;
	@property void handleDisconnect(DisconnectHandler value); /// ditto
}

// ***************************************************************************

/// An asynchronous TCP connection.
class TcpConnection : GenericSocket, IConnection
{
private:
	/// Blocks of data larger than this value are passed as unmanaged memory
	/// (in Data objects). Blocks smaller than this value will be reallocated
	/// on the managed heap. The disadvantage of placing large objects on the
	/// managed heap is false pointers; the disadvantage of using Data for
	/// small objects is wasted slack space due to the page size alignment
	/// requirement.
	enum UNMANAGED_THRESHOLD = 256;

	/// Queue of addresses to try connecting to.
	Address[] addressQueue;

	bool _connected;
	final @property bool connected(bool value) { return _connected = value; }

	bool _disconnecting;
	final @property bool disconnecting(bool value) { return _disconnecting = value; }

public:
	/// Whether the socket is connected.
	override @property bool connected() { return _connected; }

	/// Whether a disconnect is pending after all data is sent
	override @property bool disconnecting() { return _disconnecting; }

protected:
	/// The send buffers.
	Data[][MAX_PRIORITY+1] outQueue;
	/// Whether the first item from each queue has been partially sent (and thus can't be cancelled).
	bool[MAX_PRIORITY+1] partiallySent;

	/// Constructor used by a ServerSocket for new connections
	this(Socket conn)
	{
		this();
		this.conn = conn;
		connected = !(conn is null);
		if (connected)
			socketManager.register(this);
		updateFlags();
	}

	final void updateFlags()
	{
		if (!connected)
			notifyWrite = true;
		else
			notifyWrite = writePending;

		notifyRead = connected && readDataHandler;
	}

	/// Called when a socket is readable.
	override void onReadable()
	{
		// TODO: use FIONREAD when Phobos gets ioctl support (issue 6649)
		static ubyte[0x10000] inBuffer;
		auto received = conn.receive(inBuffer);

		if (received == 0)
			return disconnect("Connection closed", DisconnectType.graceful);

		if (received == Socket.ERROR)
		{
			if (wouldHaveBlocked)
			{
				debug (ASOCKETS) writefln("\t\t%s: wouldHaveBlocked or recv()", cast(void*)this);
				return;
			}
			else
				onError("recv() error: " ~ lastSocketError);
		}
		else
		{
			debug (PRINTDATA)
			{
				std.stdio.writefln("== %s <- %s ==", localAddress, remoteAddress);
				std.stdio.write(hexDump(inBuffer[0 .. received]));
				std.stdio.stdout.flush();
			}

			if (disconnecting)
			{
				debug (ASOCKETS) writefln("\t\t%s: Discarding received data because we are disconnecting", cast(void*)this);
			}
			else
			if (!readDataHandler)
			{
				debug (ASOCKETS) writefln("\t\t%s: Discarding received data because there is no data handler", cast(void*)this);
			}
			else
			{
				// Currently, unlike the D1 version of this module,
				// we will always reallocate read network data.
				// This disfavours code which doesn't need to store
				// read data after processing it, but otherwise
				// makes things simpler and safer all around.

				if (received < UNMANAGED_THRESHOLD)
				{
					// Copy to the managed heap
					readDataHandler(Data(inBuffer[0 .. received].dup));
				}
				else
				{
					// Copy to unmanaged memory
					readDataHandler(Data(inBuffer[0 .. received], true));
				}
			}
		}
	}

	/// Called when a socket is writable.
	override void onWritable()
	{
		scope(success) updateFlags();

		if (!connected)
		{
			connected = true;
			//debug writefln("[%s] Connected", remoteAddress);
			try
				setKeepAlive();
			catch (Exception e)
				return disconnect(e.msg, DisconnectType.error);
			if (connectHandler)
				connectHandler();
			return;
		}
		//debug writefln(remoteAddress(), ": Writable - handler ", handleBufferFlushed?"OK":"not set", ", outBuffer.length=", outBuffer.length);

		foreach (priority, ref queue; outQueue)
			while (queue.length)
			{
				auto pdata = queue.ptr; // pointer to first data

				ptrdiff_t sent = 0;
				if (pdata.length)
				{
					sent = conn.send(pdata.contents);
					debug (ASOCKETS) writefln("\t\t%s: sent %d/%d bytes", cast(void*)this, sent, pdata.length);
				}
				else
				{
					debug (ASOCKETS) writefln("\t\t%s: empty Data object", cast(void*)this);
				}

				if (sent == Socket.ERROR)
				{
					if (wouldHaveBlocked())
						return;
					else
						return onError("send() error: " ~ lastSocketError);
				}
				else
				if (sent < pdata.length)
				{
					if (sent > 0)
					{
						*pdata = (*pdata)[sent..pdata.length];
						partiallySent[priority] = true;
					}
					return;
				}
				else
				{
					assert(sent == pdata.length);
					//debug writefln("[%s] Sent data:", remoteAddress);
					//debug writefln("%s", hexDump(pdata.contents[0..sent]));
					pdata.clear();
					queue = queue[1..$];
					partiallySent[priority] = false;
					if (queue.length == 0)
						queue = null;
				}
			}

		// outQueue is now empty
		if (handleBufferFlushed)
			handleBufferFlushed();
		if (disconnecting)
			disconnect("Delayed disconnect - buffer flushed", DisconnectType.requested);
	}

	/// Called when an error occurs on the socket.
	override void onError(string reason)
	{
		if (!connected && addressQueue.length)
			return tryNextAddress();
		disconnect("Socket error: " ~ reason, DisconnectType.error);
	}

	final void tryNextAddress()
	{
		auto address = addressQueue[0];
		addressQueue = addressQueue[1..$];

		try
		{
			conn = new Socket(address.addressFamily(), SocketType.STREAM, ProtocolType.TCP);
			conn.blocking = false;

			socketManager.register(this);
			updateFlags();
			debug (ASOCKETS) writefln("Attempting connection to %s", address.toString());
			conn.connect(address);
		}
		catch (SocketException e)
			return onError("Connect error: " ~ e.msg);
	}

public:
	/// Default constructor
	this()
	{
		debug (ASOCKETS) writefln("New TcpConnection @ %s", cast(void*)this);
	}

	/// Start establishing a connection.
	final void connect(string host, ushort port)
	{
		if (conn || connected)
			throw new Exception("Socket object is already connected");

		try
		{
			addressQueue = getAddress(host, port);
			enforce(addressQueue.length, "No addresses found");
			if (addressQueue.length > 1)
			{
				import std.random : randomShuffle;
				randomShuffle(addressQueue);
			}
		}
		catch (SocketException e)
			return onError("Lookup error: " ~ e.msg);

		tryNextAddress();
	}

	/// Close a connection. If there is queued data waiting to be sent, wait until it is sent before disconnecting.
	/// The disconnect handler will be called when all data has been flushed.
	void disconnect(string reason = defaultDisconnectReason, DisconnectType type = DisconnectType.requested)
	{
		scope(success) updateFlags();

		if (writePending)
		{
			if (type==DisconnectType.requested)
			{
				assert(conn, "Attempting to disconnect on an uninitialized socket");
				// queue disconnect after all data is sent
				debug (ASOCKETS) writefln("[%s] Queueing disconnect: %s", remoteAddress, reason);
				assert(!disconnecting, "Attempting to disconnect on a disconnecting socket");
				disconnecting = true;
				//setIdleTimeout(30.seconds);
				return;
			}
			else
				discardQueues();
		}

		debug (ASOCKETS) writefln("[%s] Disconnecting: %s", remoteAddress, reason);
		if (conn)
		{
			socketManager.unregister(this);
			conn.close();
			conn = null;
			outQueue[] = null;
			connected = disconnecting = false;
		}
		else
		{
			assert(!connected);
		}
		if (disconnectHandler)
			disconnectHandler(reason, type);
	}

	/// Append data to the send buffer.
	void send(Data[] data, int priority = DEFAULT_PRIORITY)
	{
		assert(connected, "Attempting to send on a disconnected socket");
		assert(!disconnecting, "Attempting to send on a disconnecting socket");
		outQueue[priority] ~= data;
		notifyWrite = true; // Fast updateFlags()

		debug (PRINTDATA)
		{
			std.stdio.writefln("== %s -> %s ==", localAddress, remoteAddress);
			foreach (datum; data)
				if (datum.length)
					std.stdio.write(hexDump(datum.contents));
				else
					std.stdio.writeln("(empty Data)");
			std.stdio.stdout.flush();
		}
	}

	/// ditto
	alias send = IConnection.send;

	final void clearQueue(int priority)
	{
		if (partiallySent[priority])
		{
			assert(outQueue[priority].length > 0);
			outQueue[priority] = outQueue[priority][0..1];
		}
		else
			outQueue[priority] = null;
		updateFlags();
	}

	/// Clears all queues, even partially sent content.
	private final void discardQueues()
	{
		foreach (priority; 0..MAX_PRIORITY+1)
		{
			outQueue[priority] = null;
			partiallySent[priority] = false;
		}
		updateFlags();
	}

	@property
	final bool writePending()
	{
		foreach (queue; outQueue)
			if (queue.length)
				return true;
		return false;
	}

	final bool queuePresent(int priority)
	{
		if (partiallySent[priority])
		{
			assert(outQueue[priority].length > 0);
			return outQueue[priority].length > 1;
		}
		else
			return outQueue[priority].length > 0;
	}

public:
	private ConnectHandler connectHandler;
	/// Callback for when a connection has been established.
	@property final void handleConnect(ConnectHandler value) { connectHandler = value; updateFlags(); }

	/// Callback for when the send buffer has been flushed.
	void delegate() handleBufferFlushed;

	private ReadDataHandler readDataHandler;
	/// Callback for incoming data.
	/// Data will not be received unless this handler is set.
	@property final void handleReadData(ReadDataHandler value) { readDataHandler = value; updateFlags(); }

	private DisconnectHandler disconnectHandler;
	/// Callback for when a connection was closed.
	@property final void handleDisconnect(DisconnectHandler value) { disconnectHandler = value; updateFlags(); }
}

// ***************************************************************************

/// An asynchronous TCP connection server.
final class TcpServer
{
private:
	/// Class that actually performs listening on a certain address family
	final class Listener : GenericSocket
	{
		this(Socket conn)
		{
			debug (ASOCKETS) writefln("New Listener @ %s", cast(void*)this);
			this.conn = conn;
			socketManager.register(this);
		}

		/// Called when a socket is readable.
		override void onReadable()
		{
			Socket acceptSocket = conn.accept();
			acceptSocket.blocking = false;
			if (handleAccept)
			{
				TcpConnection connection = new TcpConnection(acceptSocket);
				connection.setKeepAlive();
				//assert(connection.connected);
				//connection.connected = true;
				acceptHandler(connection);
			}
			else
				acceptSocket.close();
		}

		/// Called when a socket is writable.
		override void onWritable()
		{
		}

		/// Called when an error occurs on the socket.
		override void onError(string reason)
		{
			close(); // call parent
		}

		void closeListener()
		{
			assert(conn);
			socketManager.unregister(this);
			conn.close();
			conn = null;
		}
	}

	/// Whether the socket is listening.
	bool listening;
	/// Listener instances
	Listener[] listeners;

	final void updateFlags()
	{
		foreach (listener; listeners)
			listener.notifyRead = handleAccept !is null;
	}

public:
	/// Start listening on this socket.
	ushort listen(ushort port, string addr = null)
	{
		debug(ASOCKETS) writefln("Attempting to listen on %s:%d", addr, port);
		//assert(!listening, "Attempting to listen on a listening socket");

		auto addressInfos = getAddressInfo(addr, to!string(port), AddressInfoFlags.PASSIVE, SocketType.STREAM, ProtocolType.TCP);

		foreach (ref addressInfo; addressInfos)
		{
			if (addressInfo.family != AddressFamily.INET && port == 0)
				continue;  // listen on random ports only on IPv4 for now

			try
			{
				Socket conn = new Socket(addressInfo);
				conn.blocking = false;
				if (addressInfo.family == AddressFamily.INET6)
					conn.setOption(SocketOptionLevel.IPV6, SocketOption.IPV6_V6ONLY, true);
				conn.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);

				conn.bind(addressInfo.address);
				conn.listen(8);

				if (addressInfo.family == AddressFamily.INET)
					port = to!ushort(conn.localAddress().toPortString());

				listeners ~= new Listener(conn);
			}
			catch (SocketException e)
			{
				debug(ASOCKETS) writefln("Unable to listen node \"%s\" service \"%s\"", addressInfo.address.toAddrString(), addressInfo.address.toPortString());
				debug(ASOCKETS) writeln(e.msg);
			}
		}

		if (listeners.length==0)
			throw new Exception("Unable to bind service");

		listening = true;

		updateFlags();

		return port;
	}

	@property Address[] localAddresses()
	{
		Address[] result;
		foreach (listener; listeners)
			result ~= listener.localAddress;
		return result;
	}

	@property bool isListening()
	{
		return listening;
	}

	/// Stop listening on this socket.
	void close()
	{
		foreach (listener;listeners)
			listener.closeListener();
		listeners = null;
		listening = false;
		if (handleClose)
			handleClose();
	}

public:
	/// Callback for when the socket was closed.
	void delegate() handleClose;

	private void delegate(TcpConnection incoming) acceptHandler;
	/// Callback for an incoming connection.
	/// Connections will not be accepted unless this handler is set.
	@property final void delegate(TcpConnection incoming) handleAccept() { return acceptHandler; }
	/// ditto
	@property final void handleAccept(void delegate(TcpConnection incoming) value) { acceptHandler = value; updateFlags(); }
}

// ***************************************************************************

/// Base class for a connection adapter.
/// By itself, does nothing.
class ConnectionAdapter : IConnection
{
	IConnection next;

	this(IConnection next)
	{
		this.next = next;
		next.handleConnect = &onConnect;
		next.handleDisconnect = &onDisconnect;
	}

	@property bool connected() { return next.connected; }
	@property bool disconnecting() { return next.disconnecting; }

	/// Queue Data for sending.
	void send(Data[] data, int priority)
	{
		next.send(data, priority);
	}

	alias send = IConnection.send; /// ditto

	/// Terminate the connection.
	void disconnect(string reason = defaultDisconnectReason, DisconnectType type = DisconnectType.requested)
	{
		next.disconnect(reason, type);
	}

	protected void onConnect()
	{
		if (connectHandler)
			connectHandler();
	}

	protected void onReadData(Data data)
	{
		// onReadData should be fired only if readDataHandler is set
		readDataHandler(data);
	}

	protected void onDisconnect(string reason, DisconnectType type)
	{
		if (disconnectHandler)
			disconnectHandler(reason, type);
	}

	/// Callback for when a connection has been established.
	@property void handleConnect(ConnectHandler value) { connectHandler = value; }
	private ConnectHandler connectHandler;

	/// Callback setter for when new data is read.
	@property void handleReadData(ReadDataHandler value)
	{
		readDataHandler = value;
		next.handleReadData = value ? &onReadData : null ;
	}
	private ReadDataHandler readDataHandler;

	/// Callback setter for when a connection was closed.
	@property void handleDisconnect(DisconnectHandler value) { disconnectHandler = value; }
	private DisconnectHandler disconnectHandler;
}

// ***************************************************************************

/// Adapter for connections with a line-based protocol.
/// Splits data stream into delimiter-separated lines.
class LineBufferedAdapter : ConnectionAdapter
{
	/// The protocol's line delimiter.
	string delimiter = "\r\n";

	this(IConnection next)
	{
		super(next);
	}

	/// Append a line to the send buffer.
	void send(string line)
	{
		//super.send(Data(line ~ delimiter));
		// https://issues.dlang.org/show_bug.cgi?id=13985
		ConnectionAdapter ca = this;
		ca.send(Data(line ~ delimiter));
	}

protected:
	/// The receive buffer.
	Data inBuffer;

	/// Called when data has been received.
	final override void onReadData(Data data)
	{
		import std.string;
		auto oldBufferLength = inBuffer.length;
		if (oldBufferLength)
			inBuffer ~= data;
		else
			inBuffer = data;

		if (delimiter.length == 1)
		{
			import core.stdc.string; // memchr

			char c = delimiter[0];
			auto p = memchr(inBuffer.ptr + oldBufferLength, c, data.length);
			while (p)
			{
				sizediff_t index = p - inBuffer.ptr;
				processLine(index);

				p = memchr(inBuffer.ptr, c, inBuffer.length);
			}
		}
		else
		{
			sizediff_t index;
			// TODO: we can start the search at oldBufferLength-delimiter.length+1
			while ((index=indexOf(cast(string)inBuffer.contents, delimiter)) >= 0)
				processLine(index);
		}
	}

	final void processLine(size_t index)
	{
		auto line = inBuffer[0..index];
		inBuffer = inBuffer[index+delimiter.length..inBuffer.length];
		super.onReadData(line);
	}

	override void onDisconnect(string reason, DisconnectType type)
	{
		super.onDisconnect(reason, type);
		inBuffer.clear();
	}
}

// ***************************************************************************

/// Fires an event handler or disconnects connections
/// after a period of inactivity.
class TimeoutAdapter : ConnectionAdapter
{
	this(IConnection next)
	{
		super(next);
	}

	void cancelIdleTimeout()
	{
		assert(idleTask !is null);
		assert(idleTask.isWaiting());
		idleTask.cancel();
	}

	void resumeIdleTimeout()
	{
		assert(connected);
		assert(idleTask !is null);
		assert(!idleTask.isWaiting());
		mainTimer.add(idleTask);
	}

	final void setIdleTimeout(Duration duration)
	{
		assert(duration > Duration.zero);
		if (idleTask is null)
		{
			idleTask = new TimerTask(duration);
			idleTask.handleTask = &onTask_Idle;
		}
		else
		{
			if (idleTask.isWaiting())
				idleTask.cancel();
			idleTask.delay = duration;
		}
		if (connected)
			mainTimer.add(idleTask);
	}

	void markNonIdle()
	{
		assert(idleTask !is null);
		if (handleNonIdle)
			handleNonIdle();
		if (idleTask.isWaiting())
			idleTask.restart();
	}

	/// Callback for when a connection has stopped responding.
	/// If unset, the connection will be disconnected.
	void delegate() handleIdleTimeout;

	/// Callback for when a connection is marked as non-idle
	/// (when data is received).
	void delegate() handleNonIdle;

protected:
	override void onReadData(Data data)
	{
		markNonIdle();
		super.onReadData(data);
	}

	override void onDisconnect(string reason, DisconnectType type)
	{
		super.onDisconnect(reason, type);
		if (idleTask && idleTask.isWaiting())
			idleTask.cancel();
	}

private:
	TimerTask idleTask;

	final void onTask_Idle(Timer timer, TimerTask task)
	{
		if (!connected)
			return;

		if (disconnecting)
			return disconnect("Delayed disconnect - time-out", DisconnectType.error);

		if (handleIdleTimeout)
		{
			handleIdleTimeout();
			if (connected && !disconnecting)
			{
				assert(!idleTask.isWaiting());
				mainTimer.add(idleTask);
			}
		}
		else
			disconnect("Time-out", DisconnectType.error);
	}
}

// ***************************************************************************

unittest
{
	void testTimer()
	{
		bool fired;
		setTimeout({fired = true;}, 10.msecs);
		socketManager.loop();
		assert(fired);
	}

	testTimer();
}
