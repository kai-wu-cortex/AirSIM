# SMS carrier icons

> 2026-11-21：用户要求恢复旧 UI，本次 PR 的视觉代码、后续截图补齐及服务号码图标已撤回。以下为历史整合记录，不代表当前界面。

Local UI assets for exact service numbers: 10086 (China Mobile), 10010 (China Unicom), 10000 (China Telecom). Contact photos take precedence on iPhone. No prefix matching or runtime image downloads.

Logo sources (downloaded 2026-11-20):
- https://companieslogo.com/china-mobile/logo/
- https://companieslogo.com/china-unicom/logo/
- https://companieslogo.com/china-telecom/logo/

Brand marks belong to their respective owners and identify the corresponding service numbers. SVG symbols are bundled unchanged.

## Banks and couriers added 2026-11-20

Exact-number mapping only. This is visual identification, not sender authentication.

- 95588 → icbc; logo: https://companieslogo.com/icbc/logo/
- 95533 → china-construction-bank; logo: https://companieslogo.com/china-construction-bank/logo/
- 95599 → agricultural-bank-of-china; logo: https://companieslogo.com/agricultural-bank-of-china/logo/
- 95566 → bank-of-china; logo: https://companieslogo.com/bank-of-china/logo/
- 95559 → bank-of-communications; logo: https://companieslogo.com/bank-of-communications/logo/
- 95338 → sf-express; logo: https://companieslogo.com/sf-express/logo/
- 950616 → jingdong-logistics; logo: https://companieslogo.com/jingdong-logistics/logo/
- 95311 → zto-express; logo: https://companieslogo.com/zto-express/logo/
- 95554 → yto-express; logo: https://companieslogo.com/yto-express/logo/

Official number references:
- ICBC: https://wap.icbc.com.cn/icbc/业务指南/电子银行/个人电子银行产品/短信银行.htm
- CCB, including 106980095533: https://finance2.ccb.cn/chn/2025-02/12/article_2025021209485982475.shtml
- ABC, including 1069095599 and 10690955998: https://www.abchina.com/cn/PersonalServices/SvcBulletin/202508/t20250827_2458070.htm
- BOC: https://www.boc.cn/ebanking/security/tips/201302/t20130205_2152054.html
- BOCOM: https://creditcard.bankcomm.com/content/dam/pc/bjk/pdf/120412-2.pdf
- SF: https://www.sf-express.com/chn/sc/notice/329
- JD: https://help.jd.com/issue/search?keyword=950616&siteId=5
- ZTO: https://www.zto.com/
- YTO: https://open.yto.net.cn/

YTO override: domestic symbol cropped from the official footer artwork at https://www.yto.net.cn/_nuxt/img/footer_logo_zh-cn.d95725d.png; international wordmark not used.

## CMB and Minsheng (2026-11-20)

- CMB: exact ports from https://cc.cmbchina.com/detail/2024110205gg_news.htm
- Minsheng: https://wap.cmbc.com.cn/sy/zygg/2024/1015625257135490.htm and https://wap.cmbc.com.cn/sy/zygg/2025/1148544611125837.htm and https://wap.cmbc.com.cn/sy/zygg/2020/211469161-548312.htm
- CMB symbol cropped from official site header: https://wwwcdn.cmbimg.cn/Images/logo.png
- Minsheng SVG symbol: https://companieslogo.com/china-minsheng-bank/logo/

## AirSIM UI-only integration

Artwork and exact display mapping adapted from 2020cqyd/AirSIM PR #47, commit b8a9bac685c4c33f5ebbc4fd641b5da7677e3086. Shared catalog used by iPhone and Watch. This does not change SMS transport, identity, encryption, or authorization.
