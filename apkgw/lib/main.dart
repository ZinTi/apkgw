import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'APK Gateway',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const ProxyGatewayHome(),
    );
  }
}

class ProxyGatewayHome extends StatefulWidget {
  const ProxyGatewayHome({super.key});

  @override
  State<ProxyGatewayHome> createState() => _ProxyGatewayHomeState();
}

class _ProxyGatewayHomeState extends State<ProxyGatewayHome> {
  // ---------- 平台通道 ----------
  static const MethodChannel _methodChannel =
  MethodChannel('com.github.zinti.apkgw/service');
  static const EventChannel _eventChannel =
  EventChannel('com.github.zinti.apkgw/events');

  // ---------- UI状态 ----------
  bool _isRunning = false;
  String _hotspotIp = '192.168.43.1'; // 默认值
  final TextEditingController _portController = TextEditingController(text: '8888');
  final List<String> _logs = [];
  final ScrollController _scrollController = ScrollController();
  final int _maxLogLines = 500;

  // ---------- 网络服务变量 ----------
  ServerSocket? _serverSocket;
  final Set<Socket> _activeClientSockets = {};
  final Set<Future<void>> _activeConnectionFutures = {};
  final int _maxConnections = 200; // 并发限制

  // ---------- 生命周期 ----------
  @override
  void initState() {
    super.initState();
    _getHotspotIp();
  }

  @override
  void dispose() {
    _stopProxyService();
    _portController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ---------- 获取热点IP (通过原生) ----------
  Future<void> _getHotspotIp() async {
    try {
      final String ip = await _methodChannel.invokeMethod('getHotspotIp');
      if (mounted) {
        setState(() {
          _hotspotIp = ip;
        });
      }
    } catch (e) {
      _addLog('WARN', '获取热点IP失败，使用默认值: $e');
    }
  }

  // ---------- 日志系统 ----------
  void _addLog(String level, String msg) {
    final timestamp = DateTime.now().toLocal().toString().substring(5, 19);
    final logLine = '[$timestamp] [$level] $msg';
    if (mounted) {
      setState(() {
        _logs.add(logLine);
        if (_logs.length > _maxLogLines) {
          _logs.removeAt(0);
        }
      });
    }
    // 自动滚到底部
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// 清空日志
  void _clearLogs() {
    setState(() {
      _logs.clear();
    });
  }

  /// 复制日志到剪贴板
  void _copyLogs() {
    if (_logs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('日志为空，无需复制')),
      );
      return;
    }
    final text = _logs.join('\n');
    Clipboard.setData(ClipboardData(text: text)).then((_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('日志已复制到剪贴板')),
      );
    });
  }

  // ---------- 开启/停止服务 ----------
  Future<void> _toggleService(bool value) async {
    if (value) {
      await _startProxyService();
    } else {
      await _stopProxyService();
    }
  }

  Future<void> _startProxyService() async {
    if (_isRunning) return;
    final portStr = _portController.text.trim();
    final port = int.tryParse(portStr);
    if (port == null || port < 1 || port > 65535) {
      _addLog('ERROR', '端口号无效，请输入1-65535之间的数字');
      return;
    }

    try {
      // 1. 启动Android前台服务 (保活)
      await _methodChannel.invokeMethod('startService', {'port': port});
      _addLog('INFO', 'Android前台服务已启动');

      // 2. 启动Dart层代理服务器
      _serverSocket = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      _addLog('INFO', '代理网关启动成功，监听 0.0.0.0:$port');

      if (mounted) {
        setState(() {
          _isRunning = true;
        });
      }

      // 3. 开始接收客户端连接（主循环）
      await _acceptLoop();
    } on SocketException catch (e) {
      _addLog('ERROR', '端口绑定失败: $e');
      await _methodChannel.invokeMethod('stopService');
      if (mounted) setState(() => _isRunning = false);
    } catch (e) {
      _addLog('ERROR', '启动服务异常: $e');
      await _methodChannel.invokeMethod('stopService');
      if (mounted) setState(() => _isRunning = false);
    }
  }

  Future<void> _stopProxyService() async {
    if (!_isRunning && _serverSocket == null) return;

    _addLog('INFO', '正在停止代理网关...');

    await _serverSocket?.close();
    _serverSocket = null;

    for (final socket in _activeClientSockets) {
      try {
        socket.destroy();
      } catch (_) {}
    }
    _activeClientSockets.clear();

    if (_activeConnectionFutures.isNotEmpty) {
      await Future.wait(_activeConnectionFutures, eagerError: false)
          .timeout(const Duration(seconds: 2), onTimeout: () {
        _addLog('WARN', '部分连接强制关闭');
        return [];
      }).catchError((_) {});
      _activeConnectionFutures.clear();
    }

    await _methodChannel.invokeMethod('stopService');
    _addLog('INFO', '代理网关已完全停止');

    if (mounted) {
      setState(() {
        _isRunning = false;
      });
    }
  }

  // ---------- 核心连接接收循环 ----------
  Future<void> _acceptLoop() async {
    final server = _serverSocket;
    if (server == null) return;

    try {
      await for (final Socket client in server) {
        if (_activeConnectionFutures.length >= _maxConnections) {
          _addLog('WARN', '并发连接已达上限$_maxConnections，拒绝新连接');
          client.close();
          continue;
        }

        final clientAddr = '${client.remoteAddress.address}:${client.remotePort}';
        _addLog('INFO', '客户端 $clientAddr 已连接');
        _activeClientSockets.add(client);

        final future = _handleClient(client, clientAddr);
        future.whenComplete(() {
          _activeClientSockets.remove(client);
          _activeConnectionFutures.remove(future);
        });
        _activeConnectionFutures.add(future);
      }
    } catch (e) {
      if (_isRunning) {
        _addLog('ERROR', '接收循环意外终止: $e');
        await _stopProxyService();
      }
    }
  }

  // ---------- 处理单个客户端（同时支持 CONNECT 和标准 HTTP 代理） ----------
  Future<void> _handleClient(Socket client, String clientAddr) async {
    List<int> buffer = [];
    bool headerComplete = false;
    String? targetHost;
    int? targetPort;
    Socket? targetServer;
    bool isClosed = false;
    final completer = Completer<void>();

    // 安全关闭
    void safeClose([String? reason]) {
      if (isClosed) return;
      isClosed = true;
      if (reason != null) _addLog('DEBUG', '关闭隧道: $reason');
      try { client.close(); } catch (_) {}
      try { targetServer?.close(); } catch (_) {}
      if (!completer.isCompleted) completer.complete();
    }

    try {
      // 使用 await for 流式读取客户端数据（单次监听）
      await for (final Uint8List chunk in client) {
        if (!headerComplete) {
          // ---------- 阶段一：解析请求头 ----------
          buffer.addAll(chunk);
          int headerEnd = -1;
          for (int i = 0; i <= buffer.length - 4; i++) {
            if (buffer[i] == 13 && buffer[i + 1] == 10 &&
                buffer[i + 2] == 13 && buffer[i + 3] == 10) {
              headerEnd = i + 4;
              break;
            }
          }
          if (headerEnd == -1) {
            if (buffer.length > 8192) {
              _addLog('WARN', '客户端 $clientAddr 请求头过大，拒绝');
              safeClose('头部过大');
              return;
            }
            continue;
          }

          final headerBytes = Uint8List.fromList(buffer.sublist(0, headerEnd));
          final remaining = Uint8List.fromList(buffer.sublist(headerEnd));
          buffer.clear();

          final requestLine = utf8.decode(headerBytes);

          // ----- 分支1: CONNECT 隧道（HTTPS/gRPC over TLS） -----
          final connectMatch = RegExp(r'^CONNECT\s+([^\s:]+):(\d+)\s+HTTP/\d\.\d')
              .firstMatch(requestLine);
          if (connectMatch != null) {
            targetHost = connectMatch.group(1)!;
            targetPort = int.parse(connectMatch.group(2)!);
            _addLog('INFO', '客户端 $clientAddr 请求隧道: $targetHost:$targetPort');

            try {
              targetServer = await Socket.connect(targetHost, targetPort,
                  timeout: const Duration(seconds: 15));
            } on TimeoutException {
              _addLog('ERROR', '连接目标 $targetHost:$targetPort 超时');
              try { client.write('HTTP/1.1 504 Gateway Timeout\r\n\r\n'); } catch (_) {}
              safeClose('连接超时');
              return;
            } on SocketException catch (e) {
              _addLog('ERROR', '连接目标 $targetHost:$targetPort 失败: $e');
              try { client.write('HTTP/1.1 502 Bad Gateway\r\n\r\n'); } catch (_) {}
              safeClose('连接目标失败');
              return;
            }

            try {
              client.write('HTTP/1.1 200 Connection Established\r\n\r\n');
              await client.flush();
            } catch (e) {
              _addLog('ERROR', '发送响应失败: $e');
              safeClose('发送响应失败');
              return;
            }
            _addLog('INFO', '隧道建立成功: $clientAddr -> $targetHost:$targetPort');

            if (remaining.isNotEmpty) {
              try {
                targetServer!.add(remaining);
              } catch (e) {
                _addLog('ERROR', '转发剩余数据失败: $e');
                safeClose('转发剩余数据失败');
                return;
              }
            }

            headerComplete = true;

            // 启动目标 -> 客户端转发
            targetServer!.listen(
                  (data) {
                try { client.add(data); } catch (e) { safeClose('目标转发错误'); }
              },
              onError: (e) { safeClose('目标监听错误'); },
              onDone: () { safeClose('目标 done'); },
              cancelOnError: true,
            );
            continue;
          }

          // ----- 分支2: 标准 HTTP 代理（GET, POST 等） -----
          final httpMatch = RegExp(r'^(\w+)\s+http://([^\s:]+)(?::(\d+))?(/[^\s]*)?\s+HTTP/(\d\.\d)')
              .firstMatch(requestLine);
          if (httpMatch != null) {
            final method = httpMatch.group(1)!;
            targetHost = httpMatch.group(2)!;
            targetPort = int.tryParse(httpMatch.group(3) ?? '80') ?? 80;
            String path = httpMatch.group(4) ?? '/';
            if (path.isEmpty) path = '/';
            final version = httpMatch.group(5)!;

            _addLog('INFO', '客户端 $clientAddr 请求 HTTP 代理: $method $targetHost:$targetPort$path');

            try {
              targetServer = await Socket.connect(targetHost, targetPort,
                  timeout: const Duration(seconds: 15));
            } on TimeoutException {
              _addLog('ERROR', '连接目标 $targetHost:$targetPort 超时');
              try { client.write('HTTP/1.1 504 Gateway Timeout\r\n\r\n'); } catch (_) {}
              safeClose('连接超时');
              return;
            } on SocketException catch (e) {
              _addLog('ERROR', '连接目标 $targetHost:$targetPort 失败: $e');
              try { client.write('HTTP/1.1 502 Bad Gateway\r\n\r\n'); } catch (_) {}
              safeClose('连接目标失败');
              return;
            }

            // 重写请求行：将绝对 URI 改为相对路径
            final newRequestLine = '$method $path HTTP/$version\r\n';
            // 找到第一行结束位置
            final firstLineEnd = requestLine.indexOf('\r\n') + 2;
            final restHeaders = headerBytes.sublist(firstLineEnd);

            try {
              targetServer!.add(utf8.encode(newRequestLine));
              targetServer!.add(restHeaders);
              if (remaining.isNotEmpty) {
                targetServer!.add(remaining);
              }
            } catch (e) {
              _addLog('ERROR', '转发 HTTP 请求失败: $e');
              safeClose('转发失败');
              return;
            }

            _addLog('INFO', 'HTTP 代理转发已建立: $clientAddr -> $targetHost:$targetPort');
            headerComplete = true;

            // 启动目标 -> 客户端转发
            targetServer!.listen(
                  (data) {
                try { client.add(data); } catch (e) { safeClose('目标转发错误'); }
              },
              onError: (e) { safeClose('目标监听错误'); },
              onDone: () { safeClose('目标 done'); },
              cancelOnError: true,
            );
            continue;
          }

          // 未知请求格式
          _addLog('WARN', '客户端 $clientAddr 请求格式错误: ${requestLine.split('\r\n').first}');
          safeClose('非 CONNECT/HTTP 请求');
          return;
        }

        // ---------- 阶段二：头部已完成，直接转发数据 ----------
        if (targetServer != null && !isClosed) {
          try {
            targetServer!.add(chunk);
          } catch (e) {
            _addLog('ERROR', '客户端->目标转发失败: $e');
            safeClose('客户端转发错误');
          }
        } else {
          _addLog('WARN', '目标未就绪，丢弃数据');
          safeClose('目标未就绪');
          return;
        }
      }
      _addLog('INFO', '客户端 $clientAddr 主动关闭');
      safeClose('客户端 done');
    } catch (e) {
      _addLog('ERROR', '处理客户端异常: $e');
      safeClose('异常');
    } finally {
      if (!completer.isCompleted) completer.complete();
    }

    await completer.future;
  }

  // ---------- UI构建 ----------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('APK 代理网关'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Card(
              child: ListTile(
                leading: const Icon(Icons.wifi, color: Colors.blue),
                title: Text('热点IP: $_hotspotIp'),
                subtitle: const Text('请将电脑的代理地址设置为该IP'),
              ),
            ),
            const SizedBox(height: 12),

            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _isRunning ? Colors.green : Colors.grey,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _isRunning ? '服务运行中' : '服务已停止',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: _isRunning ? Colors.green : Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _isRunning,
                  onChanged: _toggleService,
                  activeColor: Colors.blue,
                ),
              ],
            ),
            const SizedBox(height: 12),

            Row(
              children: [
                const Text('监听端口:'),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _portController,
                    keyboardType: TextInputType.number,
                    enabled: !_isRunning,
                    decoration: const InputDecoration(
                      hintText: '请输入端口号',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _isRunning
                      ? null
                      : () {
                    final port = int.tryParse(_portController.text);
                    if (port == null || port < 1 || port > 65535) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('请输入有效端口(1-65535)')),
                      );
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('端口已保存，点击开关启动服务')),
                      );
                    }
                  },
                  child: const Text('保存'),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // ---------- 日志控制台（带清空/复制按钮） ----------
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade200,
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(7)),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('运行日志',
                              style: TextStyle(fontWeight: FontWeight.bold)),
                          Row(
                            children: [
                              IconButton(
                                icon: const Icon(Icons.content_copy, size: 20),
                                tooltip: '复制日志',
                                onPressed: _copyLogs,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                icon: const Icon(Icons.clear, size: 20),
                                tooltip: '清空日志',
                                onPressed: _clearLogs,
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.all(8),
                        itemCount: _logs.length,
                        itemBuilder: (context, index) {
                          final log = _logs[index];
                          Color textColor;
                          if (log.contains('[ERROR]')) {
                            textColor = Colors.red;
                          } else if (log.contains('[WARN]')) {
                            textColor = Colors.orange;
                          } else if (log.contains('[INFO]')) {
                            textColor = Colors.black87;
                          } else {
                            textColor = Colors.grey;
                          }
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 1.5),
                            child: Text(
                              log,
                              style: TextStyle(
                                fontSize: 12,
                                fontFamily: 'monospace',
                                color: textColor,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
