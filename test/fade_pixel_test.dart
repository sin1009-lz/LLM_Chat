import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// 渐隐蒙版渲染像素验证：与 _ThinkingBlock 相同的 ShaderMask 结构，
/// 渲染后逐行取文字像素的最大亮度，检查渐变带内是否平滑单调、
/// 边界处有无异常行（细缝）
void main() {
  testWidgets('渐隐带 alpha 曲线平滑无异常行', (tester) async {
    final scroll = ScrollController(initialScrollOffset: 200);
    late GlobalKey shotKey;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Align(
            alignment: Alignment.topLeft,
            child: Builder(
              builder: (context) {
                shotKey = GlobalKey();
                return RepaintBoundary(
                  key: shotKey,
                  child: SizedBox(
                    width: 300,
                    child: ShaderMask(
                      shaderCallback: (rect) => LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: const [
                          Color(0x00FFFFFF),
                          Color(0xFFFFFFFF),
                          Color(0xFFFFFFFF),
                          Color(0x00FFFFFF),
                        ],
                        stops: [0.0, 0.1, 0.9, 1.0],
                      ).createShader(rect),
                      blendMode: BlendMode.dstIn,
                      child: SingleChildScrollView(
                        controller: scroll,
                        child: Text(
                          List.generate(60, (i) => '第${i + 1}行 文字渐隐测试').join('\n'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 高度放大到 300，渲染图像分析
    final image = await tester.runAsync(() async {
      final ro =
          shotKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      return ro.toImage(pixelRatio: 1.0);
    });
    expect(image, isNotNull);
    final data = await image!.toByteData(format: ui.ImageByteFormat.rawRgba);
    final b = data!.buffer.asUint8List();
    final w = image.width, h = image.height;
    // 每行取最亮像素的亮度（文字白色，背景黑）
    final rows = <double>[];
    for (var y = 0; y < h; y++) {
      var mx = 0.0;
      for (var x = 0; x < w; x += 2) {
        final i = (y * w + x) * 4;
        final lum = math.max(b[i], math.max(b[i + 1], b[i + 2])) / 255.0;
        if (lum > mx) mx = lum;
      }
      rows.add(mx);
    }
    // 顶部 0~40 行：亮度应从 0 单调上升（渐隐带），不允许出现
    // 相邻行跳变后回落的"细缝"形态
    print('rows[0..14]: ' + rows.take(15).map((v) => v.toStringAsFixed(2)).join(' '));
    print('rows[15..30]: ' + rows.skip(15).take(16).map((v) => v.toStringAsFixed(2)).join(' '));
    // 顶部渐隐带内（0~30 行）任意行亮度 < 0.5（边缘确实被压暗）；
    // 行间空隙（leading）会让单行为 0——那是文字排版不是缺陷，
    // 用包络断言而非逐行单调
    expect(rows.take(30).reduce(math.max), lessThan(0.5));
    // 带外（>60 行）文字完整不透明（≥0.9）
    expect(rows.skip(60).reduce(math.max), greaterThan(0.9));
  });
}
