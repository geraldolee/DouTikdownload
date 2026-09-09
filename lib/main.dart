import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const DouDownloaderApp());
}

class DouDownloaderApp extends StatelessWidget {
  const DouDownloaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '抖音无水印批量下载',
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

  // 博主批量扫描相关状态
  bool _isScanning = false;
  List<Map<String, dynamic>> _authorVideos = [];
  Set<String> _downloadedIds = {};
  Set<String> _selectedIds = {};
  bool _isBatchDownloading = false;
  double _batchProgress = 0.0;
  String _batchStatus = '';

  @override
  void initState() {
    super.initState();
    _loadDownloadHistory();
  }

  // 加载本地下载历史
  Future<void> _loadDownloadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _downloadedIds = (prefs.getStringList('downloaded_ids') ?? []).toSet();
    });
  }

  // 标记记录已下载
  Future<void> _markAsDownloaded(String itemId) async {
    final prefs = await SharedPreferences.getInstance();
    _downloadedIds.add(itemId);
    await prefs.setStringList('downloaded_ids', _downloadedIds.toList());
    setState(() {});
  }

  // 粘贴剪贴板
  Future<void> _pasteFromClipboard() async {
    ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data != null && data.text != null) {
      setState(() {
        _urlController.text = data.text!;
      });
      _parseUrl();
    }
  }

  // 单条链接解析
  Future<void> _parseUrl() async {
    String text = _urlController.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _isLoading = true;
      _parsedResult = null;
      _authorVideos.clear();
      _selectedIds.clear();
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
      String secUid = item['author']?['sec_uid'] ?? '';
      String nickname = item['author']?['nickname'] ?? '未知博主';
      bool isImages = item['images'] != null;

      String? videoUrl;
      if (!isImages) {
        String rawVideoUrl = item['video']['play_addr']['url_list'][0];
        videoUrl = rawVideoUrl.replaceAll('playwm', 'play');
      }

      setState(() {
        _parsedResult = {
          "id": itemId,
          "title": title,
          "cover": coverUrl,
          "video_url": videoUrl,
          "sec_uid": secUid,
          "nickname": nickname,
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

  // 扫描博主全部视频
  Future<void> _scanAuthorVideos() async {
    if (_parsedResult == null || _parsedResult!['sec_uid'].isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("未能提取博主信息，无法批量扫描")),
      );
      return;
    }

    setState(() {
      _isScanning = true;
      _authorVideos.clear();
      _selectedIds.clear();
    });

    try {
      String secUid = _parsedResult!['sec_uid'];
      // 请求博主发布列表接口 (最多抓取近期作品)
      final apiUrl = Uri.parse(
          'https://www.iesdouyin.com/web/api/v2/aweme/post/?sec_uid=$secUid&count=35&max_cursor=0');

      final res = await http.get(apiUrl, headers: {
        'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15'
      });

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        List list = data['aweme_list'] ?? [];

        List<Map<String, dynamic>> tempVideos = [];
        Set<String> autoSelected = {};

        for (var v in list) {
          String itemId = v['aweme_id'];
          String title = v['desc'] ?? '博主作品';
          String cover = v['video']['cover']['url_list'][0];
          String rawPlayUrl = v['video']['play_addr']['url_list'][0];
          String playUrl = rawPlayUrl.replaceAll('playwm', 'play');

          bool isDownloaded = _downloadedIds.contains(itemId);

          tempVideos.add({
            "id": itemId,
            "title": title,
            "cover": cover,
            "video_url": playUrl,
            "is_downloaded": isDownloaded,
          });

          // 核心点：自动勾选“未下载”的作品
          if (!isDownloaded) {
            autoSelected.add(itemId);
          }
        }

        setState(() {
          _authorVideos = tempVideos;
          _selectedIds = autoSelected;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("扫描成功！共查到 ${tempVideos.length} 个作品，已为您自动勾选 ${autoSelected.length} 个未下载作品")),
        );
      } else {
        throw Exception("博主列表获取失败");
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("扫描博主视频失败: $e")),
      );
    } finally {
      setState(() {
        _isScanning = false;
      });
    }
  }

  // 批量下载选中的视频
  Future<void> _startBatchDownload() async {
    if (_selectedIds.isEmpty) return;

    List<Map<String, dynamic>> targets =
        _authorVideos.where((v) => _selectedIds.contains(v['id'])).toList();

    setState(() {
      _isBatchDownloading = true;
      _batchProgress = 0.0;
      _batchStatus = '准备下载...';
    });

    final dir = await getApplicationDocumentsDirectory();
    int count = 0;

    for (var item in targets) {
      count++;
      setState(() {
        _batchStatus = '正在下载 ($count/${targets.length}): ${item['title']}';
        _batchProgress = count / targets.length;
      });

      try {
        String savePath = "${dir.path}/${item['id']}.mp4";
        await Dio().download(item['video_url'], savePath);
        await _markAsDownloaded(item['id']);
      } catch (e) {
        // 忽略单张失败，继续下载下一张
      }
    }

    setState(() {
      _isBatchDownloading = false;
      _batchStatus = '批量下载完成！';
      // 重新对列表状态赋值
      for (var v in _authorVideos) {
        if (_downloadedIds.contains(v['id'])) {
          v['is_downloaded'] = true;
        }
      }
      _selectedIds.clear();
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("批量下载完成并已更新下载记录！")),
    );
  }

  // 单个下载
  Future<void> _downloadSingle(String url, String itemId) async {
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("开始下载...")),
      );
      final dir = await getApplicationDocumentsDirectory();
      String savePath = "${dir.path}/$itemId.mp4";
      await Dio().download(url, savePath);
      await _markAsDownloaded(itemId);
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
        title: const Text('抖音无水印批下载', style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        backgroundColor: Colors.white,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // 输入与操作栏
            TextField(
              controller: _urlController,
              maxLines: 2,
              decoration: InputDecoration(
                hintText: '粘贴抖音视频或博主主页链接...',
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
                    label: const Text('解析链接'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.black, foregroundColor: Colors.white),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // 解析卡片
            if (_parsedResult != null)
              Card(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(_parsedResult!['cover'], width: 70, height: 90, fit: BoxFit.cover),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(_parsedResult!['title'], maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold)),
                                const SizedBox(height: 6),
                                Text("博主: ${_parsedResult!['nickname']}", style: const TextStyle(color: Colors.grey, fontSize: 12)),
                              ],
                            ),
                          )
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          if (!_parsedResult!['is_images'] && _parsedResult!['video_url'] != null)
                            Expanded(
                              child: ElevatedButton.icon(
                                onPressed: () => _downloadSingle(_parsedResult!['video_url'], _parsedResult!['id']),
                                icon: const Icon(Icons.download, size: 18),
                                label: const Text('下载单视频'),
                                style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
                              ),
                            ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _isScanning ? null : _scanAuthorVideos,
                              icon: _isScanning
                                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                                  : const Icon(Icons.radar, size: 18),
                              label: const Text('扫描博主全集'),
                            ),
                          ),
                        ],
                      )
                    ],
                  ),
                ),
              ),

            // 批量下载控制区
            if (_authorVideos.isNotEmpty) ...[
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text("博主作品 (${_authorVideos.length})", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  Text("已自动勾选未下载 (${_selectedIds.length})", style: const TextStyle(color: Colors.blue, fontSize: 12)),
                ],
              ),
              const SizedBox(height: 8),
              if (_isBatchDownloading) ...[
                LinearProgressIndicator(value: _batchProgress),
                const SizedBox(height: 4),
                Text(_batchStatus, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 8),
              ],
              ElevatedButton.icon(
                onPressed: _isBatchDownloading || _selectedIds.isEmpty ? null : _startBatchDownload,
                icon: const Icon(Icons.download_for_offline),
                label: Text('一键批量下载选中项 (${_selectedIds.length})'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(45),
                ),
              ),
              const SizedBox(height: 12),

              // 作品列表
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _authorVideos.length,
                itemBuilder: (context, index) {
                  var video = _authorVideos[index];
                  bool isDownloaded = video['is_downloaded'];
                  bool isSelected = _selectedIds.contains(video['id']);

                  return Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: CheckboxListTile(
                      value: isSelected,
                      enabled: !isDownloaded, // 已下载的禁用勾选
                      onChanged: (val) {
                        setState(() {
                          if (val == true) {
                            _selectedIds.add(video['id']);
                          } else {
                            _selectedIds.remove(video['id']);
                          }
                        });
                      },
                      title: Text(video['title'], maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                      subtitle: Text(
                        isDownloaded ? "已下载 (已忽略)" : "未下载",
                        style: TextStyle(color: isDownloaded ? Colors.green : Colors.orange, fontSize: 11),
                      ),
                      secondary: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Image.network(video['cover'], width: 40, height: 50, fit: BoxFit.cover),
                      ),
                    ),
                  );
                },
              ),
            ]
          ],
        ),
      ),
    );
  }
}
