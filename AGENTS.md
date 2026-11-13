# AGENTS.md — GNOD Gold Reload

EA MetaTrader 5 cho XAUUSD khung H1 (sóng đẩy + hồi, vào tiếp theo hướng cũ).
Repo công khai: `nvdong04/ea-gnod-gold-reload`.

## Cấu trúc

- `GNOD_Gold_Reload.mq5` — mã nguồn EA (một file).
- `GNOD_Gold_Reload.ex5` — bản biên dịch.
- `sets/GNOD_Gold_Reload_<Preset>.set` — preset (UTF-16LE, có BOM, xuống dòng CRLF).
- `compile_mt5_macos.sh` — biên dịch bằng MetaEditor qua Wine của MetaTrader 5.app.

## Build + cài

```bash
./compile_mt5_macos.sh GNOD_Gold_Reload.mq5      # phải ra "Compile SUCCESS", 0 errors
MT="$HOME/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/MQL5"
cp GNOD_Gold_Reload.mq5 GNOD_Gold_Reload.ex5 "$MT/Experts/"
cp sets/GNOD_Gold_Reload_*.set "$MT/Profiles/Tester/"
```

Cảnh báo `warning 68: version 'X.Y.Z' is incompatible with MQL5 Market` là bình thường
(version 3 phần không hợp chuẩn MQL5 Market, EA này không đăng Market).

## Nhánh git — QUAN TRỌNG

- `main` (chỉ ở máy): lịch sử làm việc nội bộ. **KHÔNG BAO GIỜ** `git push origin main`.
- `public` (ở máy) ↔ `origin/main` (GitHub): lịch sử sạch, chỉ chứa các file phát hành:
  `.gitignore`, `AGENTS.md`, `GNOD_Gold_Reload.mq5`, `GNOD_Gold_Reload.ex5`,
  `compile_mt5_macos.sh`, `sets/*.set`.
- Hai nhánh không chung lịch sử. Cập nhật GitHub bằng cách tạo commit mới trên `public`
  từ cây file phát hành của `main` (không checkout, không merge):

```bash
export GIT_INDEX_FILE="$(mktemp -u)"
git read-tree --empty
git update-index --add .gitignore AGENTS.md GNOD_Gold_Reload.mq5 GNOD_Gold_Reload.ex5 compile_mt5_macos.sh sets/*.set
TREE=$(git write-tree); rm -f "$GIT_INDEX_FILE"; unset GIT_INDEX_FILE
COMMIT=$(git commit-tree "$TREE" -p public -m "release: GNOD Gold Reload vX.Y.Z")
git branch -f public "$COMMIT"
git push origin public:main
```

- Chỉ đẩy lên GitHub / tạo release khi user yêu cầu.

## Phát hành (Release) — quy trình chuẩn

Khi user bảo "tạo release mới", làm đúng các bước sau (cùng quy ước với project EA31337).

Quy ước:
- **Version** dạng `vX.Y.Z` (3 phần, ví dụ `v1.0.0`, `v1.1.0`).
  - `Z`: sửa lỗi, không đổi hành vi giao dịch mặc định.
  - `Y`: thêm tính năng/input, đổi logic hoặc giá trị mặc định.
  - `X`: thay đổi lớn, không tương thích file `.set` cũ.
- **Tên release (title) phải TRÙNG với tag.** Ví dụ tag `v1.1.0` thì title cũng là `v1.1.0`.

### 1. Bump version
Sửa trong `GNOD_Gold_Reload.mq5` (một chỗ duy nhất, `#property version` và bảng thông tin lấy theo):
```c
#define EA_NAME    "GNOD Gold Reload"
#define EA_VERSION "X.Y.Z"                     // 3 phần, khớp tag vX.Y.Z
```
Dòng hiển thị trên chart: `=== GNOD Gold Reload vX.Y.Z ===`.

### 2. Build + cài
Như mục "Build + cài". Phải `Compile SUCCESS` (0 errors).

### 3. Đóng gói zip
```bash
STAGE="$(mktemp -d)/gnod"
mkdir -p "$STAGE/sets"
cp -f GNOD_Gold_Reload.ex5 "$STAGE/"
cp -f sets/GNOD_Gold_Reload_*.set "$STAGE/sets/"
(cd "$STAGE" && zip -q -r "GNOD_Gold_Reload_vX.Y.Z.zip" GNOD_Gold_Reload.ex5 sets)
```
Zip gồm `GNOD_Gold_Reload.ex5` (MQL5/Experts) + thư mục `sets/` (MQL5/Profiles/Tester).

### 4. Commit + push (release cần tag trên commit có code)
```bash
git add -A GNOD_Gold_Reload.mq5 GNOD_Gold_Reload.ex5 sets AGENTS.md compile_mt5_macos.sh
git commit -m "release: GNOD Gold Reload vX.Y.Z"      # trên main (ở máy)
# rồi cập nhật nhánh public và đẩy như mục "Nhánh git"
```

### 5. Tạo GitHub release
```bash
gh release create vX.Y.Z "$STAGE/GNOD_Gold_Reload_vX.Y.Z.zip" \
  --repo nvdong04/ea-gnod-gold-reload \
  --target main \
  --title "vX.Y.Z" \
  --notes "GNOD Gold Reload vX.Y.Z

<mô tả thay đổi + hướng dẫn cài + kết quả backtest tham khảo>"
```
Trả về URL dạng `https://github.com/nvdong04/ea-gnod-gold-reload/releases/tag/vX.Y.Z`.

### Lưu ý
- Ví dụ: tag `v1.0.0`, title `v1.0.0`, asset `GNOD_Gold_Reload_v1.0.0.zip`.
- `--target main` là nhánh `main` trên GitHub (tức nhánh `public` ở máy).
- Kiểm tra asset: `gh release view vX.Y.Z --repo nvdong04/ea-gnod-gold-reload --json assets --jq '.assets[].name'`.
- Khác EA31337: repo này hiện có commit file `.ex5`.

## Ghi chú kỹ thuật

- Tên biến input giữ nguyên (`RST`, `Commen`, `MaxSpred`, `percent`, `balance`…) để file `.set` cũ nạp được; chỉ sửa nhãn hiển thị và `input group`.
- Mọi giờ trong EA tính theo "giờ chuẩn" = giờ New York + 7h. Trong Strategy Tester phải nhập `ServerUTCOffsetWinter` / `ServerDSTMode` đúng với sàn (Exness: `0` / không đổi giờ).
- Lot tự động: `floor(Số dư / balance) × percent`, tính lại mỗi lần vào lệnh. Mặc định `percent=0.01`, `balance=2000`.
- Không tự thêm bộ lọc/tối ưu khi user chỉ yêu cầu phân tích báo cáo.
