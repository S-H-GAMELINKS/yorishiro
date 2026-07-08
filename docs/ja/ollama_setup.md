# Ollama セットアップガイド（yorishiro 用）

yorishiro をローカル Ollama で使うために必要な、Ollama サーバ側の設定手順。
別の PC に環境を作るときはこのドキュメントに沿って設定する。

## 検証済みの構成（このドキュメントの前提）

| 項目 | 値 |
|------|-----|
| 実行環境 | WSL2 (Ubuntu) |
| GPU | NVIDIA RTX 4070 Laptop (VRAM 8GB) |
| Ollama | 0.30.9（systemd サービスとして稼働、実行ユーザー `ollama`） |
| モデル | `gemma4:12b`（7.6GB — 8GB VRAM ではぎりぎり） |

VRAM に余裕がある PC（12GB 以上など）では後述の KV キャッシュ量子化は必須ではないが、
設定しておいて害はない。**VRAM がモデルサイズに対してぎりぎりの PC では必須**。

## なぜ設定が必要か

デフォルト設定のまま 8GB VRAM で `gemma4:12b` を動かすと、次の問題が起きる:

- `num_ctx=8192` 時の KV キャッシュ／チェックポイントの読み書きが GB 単位で発生し、
  ランナー（`llama-server`）が**長時間固まる**（クライアントのキャンセル後にスロット解放まで
  21 分かかった実測あり）
- WSL2 では CUDA のデバイス検出がタイムアウトし、Vulkan/D3D12 バックエンドへ
  フォールバックすることがあり、これも固まりの一因になる
- yorishiro は Ollama に対して read timeout を無効化している（ローカルモデルの初回
  プロンプト評価が長いため）ので、サーバ側が固まると **CLI が無反応になり
  クラッシュしたように見える**（実際にはクラッシュしていない）

## サーバ側の設定（systemd オーバーライド）

**重要:** Ollama は systemd サービス（実行ユーザー `ollama`）として動いているため、
`~/.bashrc` などシェルの環境変数は**サーバに届かない**。
サーバ向けの環境変数は必ず systemd の drop-in に書く。

### 手順

```bash
sudo mkdir -p /etc/systemd/system/ollama.service.d
sudo tee /etc/systemd/system/ollama.service.d/override.conf <<'EOF'
[Service]
Environment="OLLAMA_VULKAN=0"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
EOF

sudo systemctl daemon-reload
sudo systemctl restart ollama
```

### 各設定の意味

| 環境変数 | 値 | 目的 |
|----------|-----|------|
| `OLLAMA_VULKAN` | `0` | Vulkan バックエンドを無効化。WSL2 で CUDA 検出がタイムアウトした際の Vulkan/D3D12 フォールバック（固まりの一因）を防ぐ |
| `OLLAMA_FLASH_ATTENTION` | `1` | Flash Attention を有効化。KV キャッシュ量子化の前提条件でもある |
| `OLLAMA_KV_CACHE_TYPE` | `q8_0` | KV キャッシュを 8bit に量子化。KV のメモリ使用量が約半分になり（実測 K/V 各 34MiB）、ぎりぎりの VRAM でも `num_ctx=8192` が回る |

**q8_0 の副作用:** KV キャッシュのコンテキストシフトが無効になる。
yorishiro は送信前に自前で履歴をコンテキスト予算内にトリム／要約するため、実用上問題ない。

### 反映の確認

```bash
# 環境変数がサービスに載っているか
systemctl show ollama -p Environment | tr ' ' '\n' | grep OLLAMA

# 実際にランナーへ反映されているか（モデルロード直後のログに以下が出る）
#   --cache-type-k q8_0 --cache-type-v q8_0 --flash-attn on
journalctl -u ollama -n 100 --no-pager | grep "starting llama-server"
```

## モデルの用意

```bash
ollama pull gemma4:12b
```

VRAM が少ない PC ではより小さいモデル（`gemma3:4b`、`qwen2.5:3b` など）を検討する。
yorishiro の対応モデルは Ollama インスタンスから動的に取得されるので、
pull 済みのモデルなら何でも指定できる。

## クライアント側（yorishiro）の設定

`~/.yorishirorc`（または プロジェクトの `.lyorishirorc`）:

```ruby
use provider: :ollama, model: "gemma4:12b"
```

### コンテキストサイズ（重要な注意点）

- yorishiro は Ollama へのリクエストに明示的な `num_ctx` を送る。デフォルトは **8192**
- 変更する場合は `OLLAMA_NUM_CTX` 環境変数（クライアント側なのでシェルで OK）か、
  rc ファイルの `ollama_num_ctx 16384` で指定
- **4096 などに下げないこと。** yorishiro のコンテキスト予算は
  `num_ctx − 2048（出力用リザーブ）` で計算されるため、4096 だと実質 2048 トークンしか
  残らず、`read_file` 1回で溢れて「過剰トリム → 空応答」になる。デフォルトの 8192 を維持する
- **上げる場合の目安（gemma4:12b + RTX 4070 8GB での実測、2026-07-07）:**
  gemma4 はスライディングウィンドウ注意 + KV q8_0 のおかげで num_ctx を上げても
  KV はほとんど増えない（131072 でも KV 合計 255MiB）。実測:

  | num_ctx | 合計メモリ | CPU/GPU 分割 |
  |---------|-----------|--------------|
  | 8192    | 8.7 GB    | 32% / 68%    |
  | 16384   | 8.7 GB    | 34% / 66%    |
  | 32768   | 8.8 GB    | 35% / 65%    |
  | 65536   | 9.0 GB    | 40% / 60%    |
  | 131072  | 9.3 GB    | 45% / 55%    |
  | 262144  | 10.0 GB   | 53% / 47%    |

  **推奨は 16384**（メモリ増ほぼゼロで予算が 6144 → 14336 トークンに倍増。
  prompt 評価 932 tok/s・生成 12.9 tok/s を実測）。32768 までは実用圏。
  それ以上もロードは通るが GPU 比率が下がって生成が遅くなり、コンテキストを
  実際に埋めたときの prompt 評価時間も長くなる（＝固まりと見分けにくくなる）
- **上限は gemma4:12b の学習コンテキスト長 262144（256k）。** それを超える値
  （524288 など）を指定しても Ollama がモデル上限へ黙ってクランプする
  （`ollama ps` の CONTEXT 列とログの `n_ctx_slot` で確認可能）。
  262144 はこの構成でもロード自体は通るが、GPU 比率が半分を切り、
  仮にコンテキストを実際に埋めると prompt 評価だけで10分超かかる計算に
  なるため実用は非推奨

### その他のクライアント側環境変数

| 環境変数 | デフォルト | 用途 |
|----------|-----------|------|
| `OLLAMA_NUM_CTX` | `8192` | コンテキストウィンドウ（上記の注意を参照） |
| `OLLAMA_KEEP_ALIVE` | `10m` | モデルを VRAM に保持する時間。ターン間のロード待ちを防ぐ |
| `OLLAMA_HOST` | `http://localhost:11434` | 別ホストの Ollama を使う場合に指定 |
| `YORISHIRO_DEBUG` | - | `1` で Ollama へのリクエスト/レスポンスのデバッグログを出力 |

## トラブルシューティング

**症状: 応答が来ず CLI が無反応になる（クラッシュしたように見える）**

1. まず本当に固まっているのか確認する。yorishiro は read timeout を無効化しているので、
   初回のプロンプト評価（大きいコンテキストで数分）と固まりは見分けがつかない
2. サーバ側の状態を見る:
   ```bash
   systemctl status ollama          # プロセス自体は生きているはず（Restart 履歴がないか）
   journalctl -u ollama -f          # リクエストが処理中か、スロットが解放されないままか
   nvidia-smi                       # VRAM 使用量とプロセスの有無
   ```
3. `starting llama-server` のログ行に `--cache-type-k q8_0 --flash-attn on` が
   **含まれていない**場合、オーバーライドが効いていない。`daemon-reload` と `restart` を
   やり直す（`sudo systemctl edit` で書いた場合はファイル名が `override.conf` かも確認）
4. それでも固まりが頻発する場合は、より小さいモデルに切り替えるのが確実
