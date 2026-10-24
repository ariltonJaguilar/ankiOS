import argparse
import asyncio


async def relay(reader, writer, byte_limit):
    try:
        while data := await reader.read(64 * 1024):
            writer.write(data)
            await writer.drain()
            if byte_limit:
                await asyncio.sleep(len(data) / byte_limit)
    except (ConnectionError, OSError):
        pass
    finally:
        try:
            writer.write_eof()
        except (AttributeError, ConnectionError, OSError):
            pass


async def run(args):
    async def handle(client_reader, client_writer):
        server_reader, server_writer = await asyncio.open_connection(args.target_host, args.target_port)
        await asyncio.gather(
            relay(client_reader, server_writer, args.bytes_per_second),
            relay(server_reader, client_writer, 0),
        )
        server_writer.close()
        client_writer.close()
        await asyncio.gather(server_writer.wait_closed(), client_writer.wait_closed())

    server = await asyncio.start_server(handle, args.listen_host, args.listen_port)
    async with server:
        await server.serve_forever()


parser = argparse.ArgumentParser()
parser.add_argument("--listen-host", default="127.0.0.1")
parser.add_argument("--listen-port", type=int, default=18766)
parser.add_argument("--target-host", default="127.0.0.1")
parser.add_argument("--target-port", type=int, default=18765)
parser.add_argument("--bytes-per-second", type=int, default=32 * 1024)
asyncio.run(run(parser.parse_args()))
