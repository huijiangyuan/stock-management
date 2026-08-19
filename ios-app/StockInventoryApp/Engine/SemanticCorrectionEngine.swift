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

    /// 依据品名关键词或全文自动推断商品所属分类（应填尽填，精准推算）
    static func inferCategory(from text: String, existingCategories: [String] = []) -> String? {
        let clean = text.lowercased().replacingOccurrences(of: " ", with: "")
        guard !clean.isEmpty else { return nil }

        // 核心分类关键词规则库（支持品名、成分、用途、品牌深度推断）
        let categoryRules: [(category: String, keywords: [String])] = [
            ("食品生鲜", [
                "炸鸡", "鸡腿", "鸡翅", "鸡块", "汉堡", "薯条", "牛肉", "猪肉", "羊肉", "鸡肉",
                "牛排", "肥牛", "肉卷", "培根", "香肠", "火腿", "水产", "海鲜", "鱼", "虾", "蟹",
                "蔬菜", "水果", "苹果", "香蕉", "番茄", "鸡蛋", "面包", "吐司", "蛋糕", "饼干",
                "燕麦", "大米", "面粉", "挂面", "方便面", "零食", "糖果", "巧克力", "坚果", "冷冻食品",
                "酱油", "食用油", "花生油", "香油", "调味", "火锅底料", "番茄酱", "沙拉酱", "德克士",
                "肯德基", "麦当劳", "海底捞", "汉堡王", "塔斯汀", "双汇", "金锣", "达利园", "徐福记"
            ]),
            ("酒水饮料", [
                "可乐", "可口可乐", "百事可乐", "雪碧", "芬达", "汽水", "苏打水", "矿泉水", "饮用水",
                "纯净水", "农夫山泉", "娃哈哈", "果汁", "橙汁", "椰汁", "椰树", "牛奶", "纯牛奶",
                "酸奶", "伊利", "蒙牛", "光明", "咖啡", "拿铁", "美式", "雀巢", "星巴克", "茶叶",
                "绿茶", "红茶", "乌龙茶", "奶茶", "元气森林", "喜茶", "啤酒", "白酒", "红酒", "饮料"
            ]),
            ("日用百货", [
                "纸巾", "抽纸", "卷纸", "湿巾", "手帕纸", "洗手液", "洗洁精", "洗衣液", "洗衣粉",
                "肥皂", "香皂", "洗发水", "沐浴露", "牙膏", "牙刷", "毛巾", "抹布", "垃圾袋",
                "保鲜膜", "保鲜袋", "一次性纸杯", "一次性手套", "纸杯", "拖把", "扫把", "日用", "百货"
            ]),
            ("办公耗材", [
                "打印纸", "复印纸", "a4纸", "a3纸", "签字笔", "圆珠笔", "中性笔", "记号笔", "荧光笔",
                "订书机", "订书针", "文件夹", "资料册", "档案袋", "橡皮", "剪刀", "美工刀", "计算器",
                "墨盒", "硒鼓", "碳粉", "标签纸", "热敏纸", "便签", "记事本", "文具", "办公"
            ]),
            ("五金配件", [
                "螺栓", "螺丝", "螺母", "螺钉", "垫圈", "垫片", "轴承", "弹簧", "销轴", "卡簧",
                "铆钉", "锁具", "合页", "铰链", "滑轨", "把手", "扳手", "螺丝刀", "钳子", "锤子",
                "五金", "紧固件", "索具", "夹具", "量具", "卡尺"
            ]),
            ("金属材料", [
                "铜管", "紫铜", "黄铜", "铜排", "钢管", "不锈钢", "铝合金", "铝型材", "型材",
                "板材", "圆钢", "方管", "镀锌", "冷轧", "热轧", "碳钢", "角钢", "槽钢", "工字钢",
                "钢丝", "金属", "钢板", "铝板"
            ]),
            ("机械传动", [
                "齿轮", "皮带", "同步带", "三角带", "链条", "链轮", "联轴器", "减速机", "减速电机",
                "步进电机", "伺服电机", "电机", "马达", "气缸", "气动接头", "电磁阀", "水泵", "风机",
                "接近开关", "限位开关", "机械"
            ]),
            ("包装耗材", [
                "纸箱", "瓦楞", "编织袋", "胶带", "封箱胶", "缠绕膜", "拉伸膜", "气泡膜", "气泡袋",
                "托盘", "包装袋", "泡沫箱", "珍珠棉", "打包带", "木箱", "塑料托盘", "耗材", "包装"
            ]),
            ("化工辅料", [
                "润滑", "机油", "黄油", "润滑脂", "清洗剂", "脱脂剂", "防锈剂", "防锈油", "密封胶",
                "硅酮胶", "玻璃胶", "ab胶", "502", "树脂", "胶水", "涂料", "油漆", "固化剂",
                "稀释剂", "化工", "硅脂", "脱模剂"
            ]),
            ("电子数码", [
                "芯片", "电阻", "电容", "二极管", "三极管", "电感", "晶振", "继电器", "传感器",
                "开关", "接线端子", "插头", "插座", "电源", "适配器", "电缆", "电线", "电路板",
                "pcb", "电池", "保险丝", "元器件", "电子"
            ]),
            ("劳保用品", [
                "安全帽", "劳保手套", "防割手套", "防护服", "护目镜", "防护面罩", "防尘口罩",
                "n95", "反光背心", "安全带", "绝缘鞋", "劳保鞋", "耳塞", "防护", "劳保"
            ])
        ]

        // 1. 优先匹配已有库中用户已有的分类名称
        for existing in existingCategories {
            let cleanExisting = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanExisting.isEmpty else { continue }

            if clean.contains(cleanExisting.lowercased()) || cleanExisting.lowercased().contains(clean) {
                return cleanExisting
            }

            for rule in categoryRules {
                let matchedRuleCategory = rule.category == cleanExisting || cleanExisting.contains(rule.category) || rule.keywords.contains(where: { cleanExisting.lowercased().contains($0) })
                if matchedRuleCategory {
                    if rule.keywords.contains(where: { clean.contains($0.lowercased()) }) {
                        return cleanExisting
                    }
                }
            }
        }

        // 2. 根据内置规则库精准推算分类
        for rule in categoryRules {
            if rule.keywords.contains(where: { clean.contains($0.lowercased()) }) {
                return rule.category
            }
        }

        return nil
    }

    // MARK: - 基准单位自动推断 (Unit Inference)

    /// 依据品名形态推断常见基准计量单位（有必填，能推断就填）
    static func inferBaseUnit(from text: String) -> String {
        let clean = text.lowercased()
        if clean.contains("听") {
            return "听"
        }
        if clean.contains("罐") {
            return "罐"
        }
        if clean.contains("瓶") || clean.contains("水") || clean.contains("可乐") || clean.contains("饮料") || clean.contains("奶") || clean.contains("雪碧") {
            return "瓶"
        }
        if clean.contains("管") || clean.contains("型材") || clean.contains("轴") || clean.contains("棒") || clean.contains("笔") || clean.contains("胶条") {
            return "根"
        }
        if clean.contains("板") || clean.contains("片") || clean.contains("纸") || clean.contains("膜") {
            return "张"
        }
        if clean.contains("桶") || clean.contains("油") || clean.contains("漆") || clean.contains("乳胶") || clean.contains("脂") {
            return "桶"
        }
        if clean.contains("箱") {
            return "箱"
        }
        if clean.contains("盒") {
            return "盒"
        }
        if clean.contains("袋") || clean.contains("包") || clean.contains("粉") || clean.contains("米") || clean.contains("豆") || clean.contains("抽") {
            return "包"
        }
        if clean.contains("卷") || clean.contains("带") || clean.contains("绳") || clean.contains("线") {
            return "卷"
        }
        if clean.contains("支") || clean.contains("针") || clean.contains("牙膏") || clean.contains("硅胶") {
            return "支"
        }
        if clean.contains("双") || clean.contains("鞋") || clean.contains("手套") {
            return "双"
        }
        if clean.contains("副") || clean.contains("套") || clean.contains("具") {
            return "套"
        }
        if clean.contains("台") || clean.contains("机") || clean.contains("泵") {
            return "台"
        }
        if clean.contains("汉堡") || clean.contains("炸鸡") || clean.contains("套餐") || clean.contains("德克士") || clean.contains("快餐") {
            return "份"
        }
        if clean.contains("螺") || clean.contains("轴承") || clean.contains("垫") || clean.contains("销") || clean.contains("阀") || clean.contains("芯片") || clean.contains("电机") {
            return "个"
        }
        return "个"
    }

    // MARK: - 保质期天数严谨推断（有则填，无则坚决不填）

    /// 严格依据文本中明确包含的保质期关键词换算天数（绝不盲目瞎猜或将生产日期/数量误认）
    static func inferShelfLifeDays(from text: String) -> Int? {
        // 严格模式：必须紧跟保质期专属引导词
        let pattern = "(?:保质期|保存期|有效(?:期|天数)|Shelf\\s*Life|EXP|Best\\s*Before)[:：]?\\s*([0-9]+)\\s*(天|日|个月|月|年|days?|months?|years?)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let nsString = text as NSString
        guard let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsString.length)),
              match.numberOfRanges >= 3 else {
            return nil
        }
        let numStr = nsString.substring(with: match.range(at: 1))
        let unitStr = nsString.substring(with: match.range(at: 2)).lowercased()
        guard let num = Int(numStr), num > 0 && num <= 3650 else { return nil }

        if unitStr.contains("年") || unitStr.contains("year") {
            return num * 365
        }
        if unitStr.contains("月") || unitStr.contains("month") {
            return num * 30
        }
        if unitStr.contains("天") || unitStr.contains("日") || unitStr.contains("day") {
            return num
        }
        return nil
    }

    // MARK: - 供应商/生产商智能提取

    /// 从识别文字中尝试提取供应商或生产企业名称
    static func inferSupplier(from text: String) -> String? {
        let pattern = "(?:供应商|生产商|制造商|委托商|出品商|企业名称|品牌)[:：]?\\s*([\\u4e00-\\u9fa5A-Za-z0-9_（）()]{4,30}(?:公司|厂|行|店|集团|有限合伙))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let nsString = text as NSString
        if let match = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: nsString.length)),
           match.numberOfRanges >= 2 {
            let res = nsString.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !res.isEmpty { return res }
        }
        return nil
    }

    // MARK: - 包装规格与装箱系数推断

    struct InferredPackagingSpec {
        let unitName: String
        let conversionRatio: Double
        let unitType: String // BASE / MID / LARGE
    }

    /// 从包装文字中提取规格与装箱系数（如“24瓶/箱”、“12盒装”、“1*20袋”）
    static func inferPackagingSpecification(from text: String, baseUnit: String = "个") -> InferredPackagingSpec? {
        let clean = text.replacingOccurrences(of: " ", with: "")

        // 规则 1: 匹配 “24瓶/箱” 或 “24包/大箱”
        let pattern1 = "([0-9]+)\\s*(?:个|包|瓶|罐|盒|袋|支|份)?\\s*(?:/|每)\\s*(箱|大箱|中盒|提|件|桶)"
        if let regex = try? NSRegularExpression(pattern: pattern1, options: .caseInsensitive) {
            let ns = clean as NSString
            if let match = regex.firstMatch(in: clean, options: [], range: NSRange(location: 0, length: ns.length)),
               match.numberOfRanges >= 3 {
                let qtyStr = ns.substring(with: match.range(at: 1))
                let nameStr = ns.substring(with: match.range(at: 2))
                if let qty = Double(qtyStr), qty > 1 {
                    let type = qty >= 20 ? "LARGE" : "MID"
                    return InferredPackagingSpec(unitName: nameStr, conversionRatio: qty, unitType: type)
                }
            }
        }

        // 规则 2: 匹配 “1*24” 或 “1×12”
        let pattern2 = "(?:1|一)[*xX×]([0-9]+)\\s*(箱|盒|提|件)?"
        if let regex = try? NSRegularExpression(pattern: pattern2, options: .caseInsensitive) {
            let ns = clean as NSString
            if let match = regex.firstMatch(in: clean, options: [], range: NSRange(location: 0, length: ns.length)),
               match.numberOfRanges >= 2 {
                let qtyStr = ns.substring(with: match.range(at: 1))
                let nameStr = match.numberOfRanges >= 3 && match.range(at: 2).location != NSNotFound ? ns.substring(with: match.range(at: 2)) : "箱"
                if let qty = Double(qtyStr), qty > 1 {
                    let type = qty >= 20 ? "LARGE" : "MID"
                    return InferredPackagingSpec(unitName: nameStr, conversionRatio: qty, unitType: type)
                }
            }
        }

        // 规则 3: 匹配 “24罐装” 或 “12瓶装”
        let pattern3 = "([0-9]+)\\s*(?:个|包|瓶|罐|盒|袋)?装"
        if let regex = try? NSRegularExpression(pattern: pattern3, options: .caseInsensitive) {
            let ns = clean as NSString
            if let match = regex.firstMatch(in: clean, options: [], range: NSRange(location: 0, length: ns.length)),
               match.numberOfRanges >= 2 {
                let qtyStr = ns.substring(with: match.range(at: 1))
                if let qty = Double(qtyStr), qty > 1 {
                    let type = qty >= 20 ? "LARGE" : "MID"
                    return InferredPackagingSpec(unitName: "箱", conversionRatio: qty, unitType: type)
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
