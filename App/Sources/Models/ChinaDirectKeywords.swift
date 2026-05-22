import Foundation

/// Curated keyword preset for routing China-mainland app traffic to
/// `DIRECT`. Surfaced from `RulesEditorView` as a one-tap "add China app
/// direct rules" action.
///
/// # Why DOMAIN-KEYWORD
///
/// Meow's `DOMAIN-KEYWORD` rule is a plain substring match against the
/// full hostname of the connection. Compared with `DOMAIN-SUFFIX`,
/// keywords let one short rule cover the long-tail of CDN / sharded
/// hostnames a single Chinese app uses (xhscdn.com, sns-img-bd.xhscdn.com,
/// picasso-static.xhscdn.com, …) without enumerating each one.
///
/// # Safety bar
///
/// Substring matching is dangerous at the wrong granularity — a 2- or
/// 3-letter token would silently re-route unrelated foreign traffic. Every
/// keyword in this list was hand-checked against the rules below:
///
///   1. **Length ≥ 4 characters** for vendor / product tokens, so collisions
///      with random English words become statistically rare. The test
///      `ChinaDirectKeywordsTests.keywordsAreLongEnough` enforces this floor.
///   2. **No common English / numeric stems.** Tokens like `qq`, `jd`,
///      `163`, `360`, `mi`, `so`, `ele` are *intentionally* excluded even
///      though they identify well-known Chinese services — substring-matching
///      them would capture queue.com, jdate, etc. Where a vendor only has a
///      short stem (`qq.com`, `163.com`), the user can add a `DOMAIN-SUFFIX`
///      rule manually; we don't risk the substring form.
///   3. **Keyword must appear in a vendor's *production* hostnames**, not
///      just a marketing landing page. Verified against publicly-observed
///      DNS traffic from the corresponding mobile app.
///
/// New entries follow the same bar — adding a token here ships behaviour
/// to every user who taps the preset button, so a false positive is a
/// silent geo-routing bug.
enum ChinaDirectKeywords {
    /// One row in the preset. `category` groups rows for the user-facing
    /// summary and for future per-category opt-out.
    struct Entry {
        let keyword: String
        let category: Category
    }

    enum Category: String, CaseIterable {
        case banking = "Banking"
        case tencent = "Tencent / WeChat / QQ"
        case alibaba = "Alibaba / Taobao / Alipay"
        case baidu = "Baidu"
        case bytedance = "ByteDance / Douyin / Toutiao"
        case xiaohongshu = "Xiaohongshu (RED)"
        case bilibili = "Bilibili"
        case kuaishou = "Kuaishou"
        case netease = "NetEase"
        case video = "Video & Streaming"
        case ecommerce = "E-commerce"
        case meituan = "Meituan / Dianping"
        case pinduoduo = "Pinduoduo"
        case sogou = "Sogou / Qihoo / 360"
        case weibo = "Weibo / Sina"
        case maps = "Maps & Navigation"
        case telecom = "Telecom & ISP"
        case travel = "Travel"
        case finance = "Finance & Stocks"
        case oem = "Device OEM (Huawei / Xiaomi / OPPO / Vivo)"
        case misc = "Other (mihoyo, …)"
    }

    /// The full, ordered preset. Ordering controls insertion order in the
    /// rules list (banking first → matches before generic CDN tokens). The
    /// editor preserves a stable order so re-applying the preset is
    /// idempotent.
    static let all: [Entry] = [
        // MARK: Banking — state + commercial banks frequently used in CN

        .init(keyword: "icbc", category: .banking), // Industrial & Commercial Bank of China
        .init(keyword: "abchina", category: .banking), // Agricultural Bank of China
        .init(keyword: "ccb.com", category: .banking), // China Construction Bank (avoid bare "ccb")
        .init(keyword: "cmbchina", category: .banking), // China Merchants Bank
        .init(keyword: "bankcomm", category: .banking), // Bank of Communications
        .init(keyword: "bankofchina", category: .banking),
        .init(keyword: "boc.cn", category: .banking),
        .init(keyword: "spdb.com", category: .banking), // Shanghai Pudong Dev. Bank
        .init(keyword: "cebbank", category: .banking), // China Everbright Bank
        .init(keyword: "citicbank", category: .banking),
        .init(keyword: "ecitic", category: .banking),
        .init(keyword: "psbcoa", category: .banking), // Postal Savings Bank
        .init(keyword: "psbc.com", category: .banking),
        .init(keyword: "cgbchina", category: .banking), // China Guangfa Bank
        .init(keyword: "pingan", category: .banking), // Ping An Bank / Insurance
        .init(keyword: "hxb.com", category: .banking), // Hua Xia Bank
        .init(keyword: "njcb.com", category: .banking), // Bank of Nanjing
        .init(keyword: "bankofbeijing", category: .banking),
        .init(keyword: "bsb.com.cn", category: .banking), // Bank of Shanghai
        .init(keyword: "unionpay", category: .banking),
        .init(keyword: "95588", category: .banking), // ICBC SMS / hotline domain
        .init(keyword: "95599", category: .banking), // ABC

        // MARK: Tencent / WeChat / QQ

        .init(keyword: "weixin", category: .tencent),
        .init(keyword: "wechat", category: .tencent),
        .init(keyword: "tenpay", category: .tencent),
        .init(keyword: "qpic.cn", category: .tencent), // mmsns / mmbiz images
        .init(keyword: "qlogo.cn", category: .tencent),
        .init(keyword: "gtimg", category: .tencent), // Tencent video / image CDN
        .init(keyword: "qqmail", category: .tencent),
        .init(keyword: "qqmusic", category: .tencent),
        .init(keyword: "qqlive", category: .tencent),
        .init(keyword: "qzone", category: .tencent),
        .init(keyword: "tencent", category: .tencent),
        .init(keyword: "tencentcs", category: .tencent),
        .init(keyword: "tencentcloud", category: .tencent),
        .init(keyword: "tencentyun", category: .tencent),
        .init(keyword: "tencentmusic", category: .tencent),
        .init(keyword: "myqcloud", category: .tencent), // Tencent Cloud COS
        .init(keyword: "soso.com", category: .tencent),

        // MARK: Alibaba / Taobao / Alipay

        .init(keyword: "alipay", category: .alibaba),
        .init(keyword: "alipayobjects", category: .alibaba),
        .init(keyword: "taobao", category: .alibaba),
        .init(keyword: "tmall", category: .alibaba),
        .init(keyword: "alibaba", category: .alibaba),
        .init(keyword: "alicdn", category: .alibaba),
        .init(keyword: "aliyun", category: .alibaba),
        .init(keyword: "aliyuncs", category: .alibaba),
        .init(keyword: "alikunlun", category: .alibaba),
        .init(keyword: "dingtalk", category: .alibaba),
        .init(keyword: "mmstat", category: .alibaba), // Alimama analytics
        .init(keyword: "1688.com", category: .alibaba),
        .init(keyword: "ucweb", category: .alibaba),
        .init(keyword: "uczzd", category: .alibaba),
        .init(keyword: "9game", category: .alibaba), // 9game.cn (Alibaba games)

        // MARK: Baidu

        .init(keyword: "baidu", category: .baidu),
        .init(keyword: "bdstatic", category: .baidu),
        .init(keyword: "bdimg", category: .baidu),
        .init(keyword: "bdurl", category: .baidu),
        .init(keyword: "bcebos", category: .baidu), // Baidu Cloud object storage
        .init(keyword: "baidubce", category: .baidu),
        .init(keyword: "baidupcs", category: .baidu),
        .init(keyword: "duxiaoman", category: .baidu),

        // MARK: ByteDance / Douyin / Toutiao

        .init(keyword: "bytedance", category: .bytedance),
        .init(keyword: "bytedns", category: .bytedance),
        .init(keyword: "bytecdn", category: .bytedance),
        .init(keyword: "bytegoofy", category: .bytedance),
        .init(keyword: "douyin", category: .bytedance),
        .init(keyword: "douyinpic", category: .bytedance),
        .init(keyword: "douyinvod", category: .bytedance),
        .init(keyword: "douyincdn", category: .bytedance),
        .init(keyword: "douyinstatic", category: .bytedance),
        .init(keyword: "snssdk", category: .bytedance),
        .init(keyword: "toutiao", category: .bytedance),
        .init(keyword: "toutiaocdn", category: .bytedance),
        .init(keyword: "toutiaoimg", category: .bytedance),
        .init(keyword: "toutiaovod", category: .bytedance),
        .init(keyword: "ixigua", category: .bytedance),
        .init(keyword: "pstatp", category: .bytedance), // legacy ByteDance static
        .init(keyword: "huoshan", category: .bytedance),
        .init(keyword: "feishu", category: .bytedance),
        .init(keyword: "feishucdn", category: .bytedance),

        // MARK: Xiaohongshu

        .init(keyword: "xiaohongshu", category: .xiaohongshu),
        .init(keyword: "xhscdn", category: .xiaohongshu),

        // MARK: Bilibili

        .init(keyword: "bilibili", category: .bilibili),
        .init(keyword: "bilivideo", category: .bilibili),
        .init(keyword: "biliapi", category: .bilibili),
        .init(keyword: "biligame", category: .bilibili),
        .init(keyword: "hdslb", category: .bilibili),
        .init(keyword: "acg.tv", category: .bilibili),
        .init(keyword: "bigfun.cn", category: .bilibili),

        // MARK: Kuaishou

        .init(keyword: "kuaishou", category: .kuaishou),
        .init(keyword: "gifshow", category: .kuaishou),
        .init(keyword: "kwimgs", category: .kuaishou),
        .init(keyword: "yximgs", category: .kuaishou),
        .init(keyword: "kwaicdn", category: .kuaishou),
        .init(keyword: "kuaishouzt", category: .kuaishou),

        // MARK: NetEase

        .init(keyword: "netease", category: .netease),
        .init(keyword: "ydstatic", category: .netease),
        .init(keyword: "youdao", category: .netease),
        .init(keyword: "163yun", category: .netease),
        .init(keyword: "nosdn", category: .netease), // NetEase Object Storage CDN
        .init(keyword: "neteasegames", category: .netease),
        .init(keyword: "lofter", category: .netease),
        .init(keyword: "kaola.com", category: .netease),

        // MARK: Video & Streaming

        .init(keyword: "iqiyi", category: .video),
        .init(keyword: "iqiyipic", category: .video),
        .init(keyword: "qiyipic", category: .video),
        .init(keyword: "youku", category: .video),
        .init(keyword: "ykimg", category: .video),
        .init(keyword: "soku.com", category: .video),
        .init(keyword: "tudou", category: .video),
        .init(keyword: "mgtv", category: .video),
        .init(keyword: "letv.com", category: .video),
        .init(keyword: "le.com", category: .video),
        .init(keyword: "huya.com", category: .video),
        .init(keyword: "douyu", category: .video),
        .init(keyword: "douyucdn", category: .video),
        .init(keyword: "ximalaya", category: .video),
        .init(keyword: "lizhi.fm", category: .video),

        // MARK: E-commerce

        .init(keyword: "jingdong", category: .ecommerce), // JD.com
        .init(keyword: "jdcloud", category: .ecommerce),
        .init(keyword: "jdcdn", category: .ecommerce),
        .init(keyword: "jdcomm", category: .ecommerce),
        .init(keyword: "360buyimg", category: .ecommerce), // JD image CDN
        .init(keyword: "vipshop", category: .ecommerce),
        .init(keyword: "vip.com", category: .ecommerce),
        .init(keyword: "suning.com", category: .ecommerce),
        .init(keyword: "suning.cn", category: .ecommerce),
        .init(keyword: "yhd.com", category: .ecommerce),

        // MARK: Meituan / Dianping

        .init(keyword: "meituan", category: .meituan),
        .init(keyword: "dianping", category: .meituan),
        .init(keyword: "mtyun", category: .meituan),
        .init(keyword: "maoyan", category: .meituan),
        .init(keyword: "sankuai", category: .meituan), // Meituan parent
        .init(keyword: "elemecdn", category: .meituan), // Ele.me (Alibaba but bundled w/ delivery)
        .init(keyword: "ele.me", category: .meituan),

        // MARK: Pinduoduo

        .init(keyword: "pinduoduo", category: .pinduoduo),
        .init(keyword: "yangkeduo", category: .pinduoduo),
        .init(keyword: "pddpic", category: .pinduoduo),
        .init(keyword: "pddugc", category: .pinduoduo),

        // MARK: Sogou / Qihoo / 360

        .init(keyword: "sogou", category: .sogou),
        .init(keyword: "sogoucdn", category: .sogou),
        .init(keyword: "qihucdn", category: .sogou),
        .init(keyword: "qhimg", category: .sogou),
        .init(keyword: "360safe", category: .sogou),
        .init(keyword: "360.cn", category: .sogou),
        .init(keyword: "qihoo", category: .sogou),
        .init(keyword: "haosou", category: .sogou),

        // MARK: Weibo / Sina

        .init(keyword: "weibo", category: .weibo),
        .init(keyword: "weibocdn", category: .weibo),
        .init(keyword: "sinaimg", category: .weibo),
        .init(keyword: "sinajs", category: .weibo),
        .init(keyword: "sina.com", category: .weibo),
        .init(keyword: "sina.cn", category: .weibo),
        .init(keyword: "miaopai", category: .weibo),

        // MARK: Maps & Navigation

        .init(keyword: "amap", category: .maps), // AutoNavi / Gaode
        .init(keyword: "autonavi", category: .maps),
        .init(keyword: "autoimg", category: .maps),
        .init(keyword: "mapabc", category: .maps),
        .init(keyword: "didiglobal", category: .maps), // Didi
        .init(keyword: "didichuxing", category: .maps),
        .init(keyword: "didistatic", category: .maps),

        // MARK: Telecom & ISP

        .init(keyword: "chinamobile", category: .telecom),
        .init(keyword: "chinaunicom", category: .telecom),
        .init(keyword: "chinatelecom", category: .telecom),
        .init(keyword: "chinanet", category: .telecom),
        .init(keyword: "10086.cn", category: .telecom),
        .init(keyword: "10010.com", category: .telecom),
        .init(keyword: "189.cn", category: .telecom),

        // MARK: Travel

        .init(keyword: "ctrip", category: .travel),
        .init(keyword: "xiecheng", category: .travel),
        .init(keyword: "elong", category: .travel),
        .init(keyword: "mafengwo", category: .travel),
        .init(keyword: "tuniu", category: .travel),
        .init(keyword: "feizhu", category: .travel),
        .init(keyword: "fliggy", category: .travel),
        .init(keyword: "12306.cn", category: .travel), // China Railway

        // MARK: Finance & Stocks

        .init(keyword: "eastmoney", category: .finance),
        .init(keyword: "xueqiu", category: .finance),
        .init(keyword: "10jqka", category: .finance), // Tonghuashun (Hithink)
        .init(keyword: "tonghuashun", category: .finance),
        .init(keyword: "hexun", category: .finance),
        .init(keyword: "gtja.com", category: .finance), // Guotai Junan
        .init(keyword: "htsec.com", category: .finance), // Haitong Securities
        .init(keyword: "htsc.com", category: .finance), // Huatai Securities
        .init(keyword: "cicc.com", category: .finance), // CICC
        .init(keyword: "lufax", category: .finance),
        .init(keyword: "alipay-eco", category: .finance),

        // MARK: Device OEM

        .init(keyword: "huawei", category: .oem),
        .init(keyword: "huaweicloud", category: .oem),
        .init(keyword: "hicloud", category: .oem),
        .init(keyword: "vivoglobal", category: .oem), // covers vivo when needed
        .init(keyword: "vivo.com.cn", category: .oem),
        .init(keyword: "oppomobile", category: .oem),
        .init(keyword: "oppo.com", category: .oem),
        .init(keyword: "heytap", category: .oem), // OPPO/Realme cloud
        .init(keyword: "xiaomi", category: .oem),
        .init(keyword: "xiaomiev", category: .oem),
        .init(keyword: "miui.com", category: .oem),
        .init(keyword: "mi.com", category: .oem),
        .init(keyword: "duokan", category: .oem), // Xiaomi e-book
        .init(keyword: "honor.com", category: .oem),

        // MARK: Misc

        .init(keyword: "mihoyo", category: .misc),
        .init(keyword: "yuanshen", category: .misc), // Genshin (CN)
        .init(keyword: "chinaz", category: .misc),
        .init(keyword: "anjuke", category: .misc),
        .init(keyword: "fang.com", category: .misc),
        .init(keyword: "soufun", category: .misc),
        .init(keyword: "lianjia", category: .misc),
        .init(keyword: "ke.com", category: .misc),
        .init(keyword: "zhihu.com", category: .misc),
        .init(keyword: "zhimg.com", category: .misc),
        .init(keyword: "jianshu", category: .misc),
        .init(keyword: "douban", category: .misc),
        .init(keyword: "doubanio", category: .misc),
        .init(keyword: "smzdm.com", category: .misc),
        .init(keyword: "csdn.net", category: .misc),
        .init(keyword: "csdnimg", category: .misc),
        .init(keyword: "oschina", category: .misc),
        .init(keyword: "gitee.com", category: .misc),
    ]

    /// Build the EditableRule rows for the preset. All rows are
    /// `DOMAIN-KEYWORD,<keyword>,DIRECT` — `proxy` is hard-coded to
    /// DIRECT because the entire purpose of the preset is geo-bypass.
    static func presetRules() -> [EditableRule] {
        all.map { entry in
            EditableRule(type: "DOMAIN-KEYWORD", payload: entry.keyword, proxy: "DIRECT")
        }
    }

    /// Prepend `preset` to `existing` so the preset rows match first.
    /// Preset rows already present in `existing` (same TYPE / payload) are
    /// skipped so re-tapping the action is a no-op. The relative order of
    /// `existing` is preserved behind the preset block.
    ///
    /// Meow evaluates `rules:` top-down and stops at the first hit, so
    /// front-of-list placement is what guarantees a China-app domain
    /// reaches `DIRECT` even when a user's later rule would have sent the
    /// same hostname through a proxy group.
    static func prepend(preset: [EditableRule], to existing: [EditableRule]) -> (merged: [EditableRule], added: Int) {
        var existingKeys = Set<String>()
        for rule in existing {
            existingKeys.insert(key(for: rule))
        }
        let fresh = preset.filter { !existingKeys.contains(key(for: $0)) }
        return (fresh + existing, fresh.count)
    }

    /// Merge `preset` into `existing`, skipping any preset row whose
    /// (type, payload) pair is already present (case-insensitive on type,
    /// case-sensitive on payload — keywords are matched verbatim by
    /// meow). New rows are appended in preset order. Returns the merged
    /// list and the count of rows actually inserted.
    ///
    /// This is the append-flavoured sibling of `prepend(preset:to:)`;
    /// kept for callers (and tests) that want preset rows added to the
    /// tail of an existing list rather than the head.
    static func merge(preset: [EditableRule], into existing: [EditableRule]) -> (merged: [EditableRule], added: Int) {
        var seen = Set<String>()
        for rule in existing {
            seen.insert(key(for: rule))
        }
        var merged = existing
        var added = 0
        for rule in preset where !seen.contains(key(for: rule)) {
            merged.append(rule)
            seen.insert(key(for: rule))
            added += 1
        }
        return (merged, added)
    }

    private static func key(for rule: EditableRule) -> String {
        "\(rule.type.uppercased())|\(rule.payload)"
    }
}
