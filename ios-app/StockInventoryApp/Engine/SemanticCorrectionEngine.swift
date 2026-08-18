import Foundation

/// 端侧智能语义纠错与商品品类/单位自动推理引擎
/// 负责在毫秒级内完成：
/// 1. OCR 常见形近字与品牌/物料名称纠错（如“德克上” -> “德克士”）；
/// 2. 基于品名关键词自动推理所属分类（如“德克士” -> “食品餐饮”）；
/// 3. 基于物料形态自动推断基准单位与默认保质期。
struct SemanticCorrectionEngine {

    // MARK: - 常用品牌与物料专有名词词典（用于 OCR 模糊纠错）

    private static let knownEntities: [String] = [
        // 餐饮与快消品牌
        "德克士", "肯德基", "麦当劳", "星巴克", "必胜客", "华莱士", "汉堡王", "海底捞", "塔斯汀",
        "可口可乐", "百事可乐", "康师傅", "统一", "雀巢", "娃哈哈", "农夫山泉", "加多宝", "王老吉",
        "元气森林", "喜茶", "奈雪的茶", "蜜雪冰城", "奥利奥", "达利园", "徐福记", "三只松鼠",
        "良品铺子", "百草味", "洽洽", "双汇", "金锣", "蒙牛", "伊利", "光明", "旺旺",
        // 常见食品与快餐品类词
        "脆皮炸鸡", "香辣鸡腿堡", "超级汉堡", "黄金鸡块", "薯条", "黑咖啡", "美式咖啡", "拿铁咖啡",
        "珍珠奶茶", "原味即食燕麦", "全脂纯牛奶", "浓缩果汁", "苏打水", "苏打饼干", "吐司面包",
        // 工业材料与五金配件
        "高纯度铜管", "无缝不锈钢管", "铝合金型材", "冷轧钢板", "热轧钢板", "镀锌钢管", "聚氯乙烯管",
        "精密微型轴承", "深沟球轴承", "圆锥滚子轴承", "不锈钢内六角螺栓", "外六角螺栓", "法兰螺母",
        "自攻螺丝", "平垫圈", "弹簧垫圈", "开口销", "圆柱销", "同步带", "三角皮带", "精密齿轮",
        "联轴器", "气动接头", "电磁阀", "气缸", "伺服电机", "步进电机", "减速电机", "接近开关",
        // 化工与辅料
        "特级润滑硅脂", "全合成机油", "工业润滑油", "黄油润滑脂", "螺纹紧固胶", "防锈润滑剂",
        "工业清洗剂", "强力脱脂剂", "硅酮密封胶", "环氧树脂AB胶",
        // 包装与耗材
        "五层瓦楞纸箱", "三层纸箱", "高强度编织袋", "透明封箱胶带", "拉伸缠绕膜", "气泡防震膜",
        "自封包装袋", "免熏蒸木托盘", "塑料托盘",
        // 电子元器件
        "贴片电阻", "贴片电容", "电解电容", "发光二极管", "稳压二极管", "微控制器芯片",
        "集成电路", "继电器", "接线端子", "传感器", "保险丝", "电源适配器"
    ]

    // MARK: - 文本自动纠错

    /// 对 OCR 识别出的粗文本进行品牌与物料名称智能纠错
    static func correctText(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var result = trimmed

        // 1. 常见 OCR 易混淆形近字替换规则
        let replacements: [(String, String)] = [
            ("德克上", "德克士"),
            ("德克土", "德克士"),
            ("肯德基堡", "肯德基"),
            ("可口町乐", "可口可乐"),
            ("百事町乐", "百事可乐"),
            ("不锈铜", "不锈钢"),
            ("铜管材", "铜管"),
            ("螺栓钉", "螺栓"),
            ("深沟球轴", "深沟球轴承")
        ]

        for (pattern, target) in replacements {
            if result.contains(pattern) {
                result = result.replacingOccurrences(of: pattern, with: target)
            }
        }

        // 2. 与专有名词词典进行编辑距离模糊比对（若编辑距离为 1 且长度 >= 3，自动修正）
        for known in knownEntities {
            if result == known { return known }
            if result.count == known.count && result.count >= 3 {
                let dist = levenshteinDistance(result, known)
                if dist == 1 {
                    return known
                }
            }
        }

        return result
    }

    // MARK: - 品类自动推理 (Category Inference)

    /// 依据品名关键词或全文自动推断商品所属分类
    static func inferCategory(from text: String, existingCategories: [String] = []) -> String? {
        let clean = text.lowercased().replacingOccurrences(of: " ", with: "")
        guard !clean.isEmpty else { return nil }

        // 核心分类关键词规则库（支持词根及细分词素）
        let categoryRules: [(category: String, keywords: [String])] = [
            ("食品餐饮", [
                "德克士", "肯德基", "麦当劳", "汉堡", "炸鸡", "鸡腿", "鸡块", "薯条", "堡", "咖啡",
                "奶茶", "可乐", "牛奶", "果汁", "饮料", "面包", "饼干", "蛋糕", "燕麦", "零食",
                "牛肉", "鸡肉", "猪肉", "海鲜", "蔬菜", "水果", "调味", "酱油", "食用油", "大米",
                "面粉", "方便面", "罐头", "糖果", "巧克力", "茶叶", "饮用水", "冰淇淋", "餐饮", "食品", "快餐"
            ]),
            ("五金配件", [
                "螺栓", "螺丝", "螺母", "螺钉", "垫圈", "垫片", "轴承", "弹簧", "销轴", "卡簧",
                "铆钉", "锁具", "合页", "滑轨", "把手", "五金", "紧固件", "索具", "夹具"
            ]),
            ("金属材料", [
                "铜管", "铜排", "紫铜", "黄铜", "钢管", "不锈钢", "铝合金", "型材", "板材", "圆钢",
                "方管", "镀锌", "冷轧", "热轧", "碳钢", "角钢", "槽钢", "工字钢", "钢丝", "金属", "钢板"
            ]),
            ("机械传动", [
                "齿轮", "皮带", "同步带", "链条", "链轮", "联轴器", "减速机", "电机", "马达",
                "气缸", "气动", "液压", "阀门", "电磁阀", "水泵", "风机", "机械"
            ]),
            ("包装材料", [
                "纸箱", "瓦楞", "编织袋", "胶带", "缠绕膜", "气泡膜", "托盘", "包装袋", "泡沫",
                "木箱", "塑料袋", "封口胶", "耗材", "包装"
            ]),
            ("化工辅料", [
                "润滑", "机油", "黄油", "清洗剂", "脱脂剂", "防锈", "密封胶", "树脂", "胶水",
                "涂料", "油漆", "固化剂", "溶剂", "稀释剂", "化工", "硅脂"
            ]),
            ("电子元器件", [
                "芯片", "电阻", "电容", "二极管", "三极管", "电感", "晶振", "继电器", "传感器",
                "开关", "接线端", "插头", "电缆", "电路板", "元器件", "电子"
            ]),
            ("劳保日化", [
                "手套", "口罩", "安全帽", "防护服", "护目镜", "洗手液", "消毒液", "毛巾", "抹布",
                "洗衣液", "劳保", "日化", "清洁"
            ]),
            ("办公文具", [
                "打印纸", "复印纸", "签字笔", "订书机", "文件夹", "档案袋", "橡皮", "剪刀",
                "计算器", "墨盒", "硒鼓", "文具", "办公"
            ])
        ]

        // 1. 优先匹配已有库中用户自定义分类
        for existing in existingCategories {
            let cleanExisting = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanExisting.isEmpty else { continue }

            // 如果现有分类名称与待识别文本有交集（如现有分类“西式快餐”，识别到“德克士炸鸡快餐”）
            if clean.contains(cleanExisting.lowercased()) || cleanExisting.lowercased().contains(clean) {
                return cleanExisting
            }

            for rule in categoryRules {
                // 如果现有分类命中了规则库中的任一分类语义
                let matchedRuleCategory = rule.category == cleanExisting || cleanExisting.contains(rule.category) || rule.keywords.contains(where: { cleanExisting.lowercased().contains($0) })
                if matchedRuleCategory {
                    if rule.keywords.contains(where: { clean.contains($0.lowercased()) }) {
                        return cleanExisting
                    }
                }
            }
        }

        // 2. 根据内置规则库匹配推荐分类
        for rule in categoryRules {
            if rule.keywords.contains(where: { clean.contains($0.lowercased()) }) {
                return rule.category
            }
        }

        return nil
    }

    // MARK: - 基准单位自动推断 (Unit Inference)

    /// 依据品名形态推断常见基准计量单位
    static func inferBaseUnit(from text: String) -> String {
        let clean = text.lowercased()
        if clean.contains("管") || clean.contains("型材") || clean.contains("轴") || clean.contains("棒") {
            return "根"
        }
        if clean.contains("板") || clean.contains("片") {
            return "张"
        }
        if clean.contains("油") || clean.contains("水") || clean.contains("饮料") || clean.contains("奶") || clean.contains("剂") || clean.contains("脂") {
            if clean.contains("桶") || clean.contains("脂") || clean.contains("润滑") { return "桶" }
            if clean.contains("罐") { return "罐" }
            return "瓶"
        }
        if clean.contains("箱") {
            return "箱"
        }
        if clean.contains("袋") || clean.contains("包") || clean.contains("粉") || clean.contains("米") || clean.contains("豆") {
            return "包"
        }
        if clean.contains("卷") || clean.contains("带") || clean.contains("膜") {
            return "卷"
        }
        if clean.contains("螺") || clean.contains("轴承") || clean.contains("垫") || clean.contains("销") || clean.contains("阀") || clean.contains("芯片") || clean.contains("电机") {
            return "个"
        }
        if clean.contains("汉堡") || clean.contains("炸鸡") || clean.contains("套餐") || clean.contains("德克士") || clean.contains("堡") {
            return "份"
        }
        return "个"
    }

    // MARK: - 保质期天数智能推断

    /// 依据品类或文本中包含的保质期描述自动换算天数
    static func inferShelfLifeDays(from text: String) -> Int? {
        let pattern = "(?:保质期|保存期|EXP)?\\s*([0-9]+)\\s*(天|日|个月|月|年)"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let nsString = text as NSString
            if let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsString.length)),
               match.numberOfRanges >= 3 {
                let numStr = nsString.substring(with: match.range(at: 1))
                let unitStr = nsString.substring(with: match.range(at: 2))
                if let num = Int(numStr) {
                    if unitStr.contains("年") { return num * 365 }
                    if unitStr.contains("月") { return num * 30 }
                    return num
                }
            }
        }
        return nil
    }

    // MARK: - 辅助计算：Levenshtein 编辑距离

    private static func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1)
        let b = Array(s2)
        let m = a.count
        let n = b.count

        if m == 0 { return n }
        if n == 0 { return m }

        var matrix = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)

        for i in 0...m { matrix[i][0] = i }
        for j in 0...n { matrix[0][j] = j }

        for i in 1...m {
            for j in 1...n {
                if a[i - 1] == b[j - 1] {
                    matrix[i][j] = matrix[i - 1][j - 1]
                } else {
                    matrix[i][j] = min(
                        matrix[i - 1][j] + 1,      // 删除
                        matrix[i][j - 1] + 1,      // 插入
                        matrix[i - 1][j - 1] + 1   // 替换
                    )
                }
            }
        }
        return matrix[m][n]
    }
}
