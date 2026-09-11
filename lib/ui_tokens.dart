import 'package:flutter/material.dart';

// ──────────────────────────────────────────────────────────────
// UI 设计令牌（Design Tokens）
//
// 所有文件的圆角/间距/语义色统一引用本文件，避免硬编码魔法数字。
// 依赖方向：main.dart / settings_page.dart / markdown_view.dart → 本文件
// ──────────────────────────────────────────────────────────────

// ── 圆角（8 级，每级有对应令牌）──
const kRadiusXxs = 4.0; // 极小（角标/紧凑圆角）
const kRadiusXs = 6.0; // 小圆角（小标签）
const kRadiusSm = 10.0; // 小（chip/文件块/分段按钮）
const kRadiusMd = 12.0; // 中（按钮/保存/取消）
const kRadiusLg = 14.0; // 大（卡片/列表项/设置 tile）
const kRadiusBubble = 16.0; // 消息气泡
const kRadiusXl = 20.0; // 极大（底部弹窗/对话框）
const kRadiusPill = 24.0; // 胶囊（页眉/大圆按钮）

// 注意：_GlassInputBar._radius=28 是结构几何（按钮直径推导源），
// 独立于本体系，勿改

// ── 间距（7 级）──
const kGapXxs = 2.0;
const kGapXs = 4.0;
const kGapSm = 8.0;
const kGapMd = 12.0;
const kGapLg = 16.0;
const kGapXl = 20.0;
const kGapXxl = 24.0;

// ── 语义色 ──
const kSuccessColor = Color(0xFF4FC3F7); // 浅蓝·暗色模式（原绿 2E7D32）
// 浅色模式用深一档的蓝（4FC3F7 在白底上对比度不足，发灰看不清）
const kSuccessColorLight = Color(0xFF0288D1);
const kErrorColor = Color(0xFFC62828);
const kSheetBgDark = Color(0xFF1C1C1E);

// ── 底色 alpha 规范（仅静态字面值用）──
// 0.10 = 微透明底     0.15 = 卡片/按钮底（_buttonColor 标准）
// 0.20 = 选中/强调底  0.30 = 更深底色
// 0.40 = 禁用底       0.50 = 半透明强调
//
// 注意：动画表达式中的 alpha（如 0.25*(1-t)、tt*0.35）是时序手感值，
// 不纳入本体系，勿统一；markdown_view.dart 的 0.04/0.6/0.7/0.8 属于
// 文字透明度维度，同样不纳入底色 alpha 体系
//
// 保留不并入的例外：
// · grey alpha 0.25 = 边框/轨道/特殊底色（与 0.20/0.30 有语义区别）
// · 0xFF262626 / 0xFFF2F2F2 = 思考块亮暗配对色（独立于灰度 shade 体系）
// · 0xFFE8E8E8 / kSheetBgDark = 抽屉面板亮暗配对色（同上）

// ── 错误色规则 ──
// Material 组件语境（TextButton.styleFrom 等）用 colorScheme.error；
// 自绘/自定义组件用 kErrorColor

// ── 文件适用范围 ──
// main.dart / settings_page.dart 统一引用本文件；
// markdown_view.dart 的排版间距（行高/列表间距/代码块 padding）独立于
// 本间距体系（属于富文本排版维度），不纳入，避免与文本排版规则冲突
