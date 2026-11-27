import '../server/server_host.dart';

/// بيشغّل السيرفر في Isolate لوحده ويرجّع البورت.
Future<int> startEmbeddedServer(String dataDir) => ServerHost.start(dataDir);
