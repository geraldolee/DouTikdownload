import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  runApp(const DouDownloaderApp());
}

class DouDownloaderApp extends StatelessWidget {
  const DouDownloaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '抖音无水印下载',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.black),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF5F5F7),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _urlController = TextEditingController();
  bool _isLoading = false;
  Map<String, dynamic>? _parsedResult;

  // 读取剪贴板
  Future<void> _pasteFromClipboard() async {
    ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data != null && data.text != null) {
      setState(() {
        _urlController.text = data.text!;
      });
      _parseUrl();
    }
  }

  // 纯客户端抖音链接解析逻辑
  Future<void> _parseUrl() async {
    String text = _urlController.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _isLoading = true;
      _parsedResult = null;
    });

    try {
      final urlRegExp = RegExp(r'https?://[^\s]+');
      final match = urlRegExp.firstMatch(text);
      if (match == null) throw Exception("未找到有效的抖音链接");
      String shareUrl = match.group(0)!;

      final client = http.Client();
      final request = http.Request('GET', Uri.parse(shareUrl))
        ..followRedirects = false
        ..headers['User-Agent'] =
            'Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1';

      final response = await client.send(request);
      String realUrl = response.headers['location'] ?? shareUrl;

      final idRegExp = RegExp(r'(?:video|note)/(\d+)');
      final idMatch = idRegExp.firstMatch(realUrl);
      if (idMatch == null) throw Exception("无法获取作品 ID");
      String itemId = idMatch.group(1)!;

      final apiUrl = Uri.parse(
          'https://www.iesdouyin.com/web/api/v2/aweme/iteminfo/?item_ids=$itemId');
      final apiRes = await http.get(apiUrl, headers: {
        'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15'
      });

      if (apiRes.statusCode != 200) throw Exception("获取视频信息失败");

      final data = jsonDecode(apiRes.body);
      if (data['item_list'] == null || (data['item_list'] as List).isEmpty) {
        throw Exception("作品信息不存在或已被删除");
      }

      final item = data['item_list'][0];
      String title = item['desc'] ?? '抖音无水印作品';
      String coverUrl = item['video']['cover']['url_list'][0];
      bool isImages = item['images'] != null;

      String? videoUrl;
      List<String> images = [];

      if (isImages) {
        for (var img in item['images']) {
          images.add(img['url_list'][0]);
        }
      } else {
        String rawVideoUrl = item['video']['play_addr']['url_list'][0];
        videoUrl = rawVideoUrl.replaceAll('playwm', 'play');
      }

      setState(() {
        _parsedResult = {
          "title": title,
          "cover": coverUrl,
          "video_url": videoUrl,
          "images": images,
          "is_images": isImages,
        };
      });
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("解析失败: $e")),
      );
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  // 下载文件保存
  Future<void> _downloadFile(String url, String fileName) async {
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("开始下载...")),
      );
      final dir = await getApplicationDocumentsDirectory();
      String savePath = "${dir.path}/$fileName";
      await Dio().download(url, savePath);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("保存成功：$savePath")),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("下载失败: $e")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('抖音无水印下载', style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        backgroundColor: Colors.white,
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            TextField(
              controller: _urlController,
              maxLines: 2,
              decoration: InputDecoration(
                hintText: '粘贴抖音分享链接...',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                filled: true,
                fillColor: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pasteFromClipboard,
                    icon: const Icon(Icons.content_paste),
                    label: const Text('粘贴'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _isLoading ? null : _parseUrl,
                    icon: _isLoading
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.search),
                    label: const Text('解析'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.black, foregroundColor: Colors.white),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (_parsedResult != null)
              Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      Text(_parsedResult!['title'], style: const TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 12),
                      if (!_parsedResult!['is_images'] && _parsedResult!['video_url'] != null)
                        ElevatedButton.icon(
                          onPressed: () => _downloadFile(_parsedResult!['video_url'], "${DateTime.now().millisecondsSinceEpoch}.mp4"),
                          icon: const Icon(Icons.download),
                          label: const Text('保存无水印视频'),
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
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
