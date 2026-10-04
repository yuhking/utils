unit Unit1;

{
  IMAP添付ファイル削除ツール - 単一画面版 (Delphi XE5 / Indy10)
  --------------------------------------------------------------
  ・接続設定（旧Unit2/Form2）を左パネルに統合し、1画面で完結。
  ・流れは「接続 → 一覧 → 選択 → 更新」（接続後は一覧取得まで自動で実行）。
      [接続]        左パネルの入力内容でIMAPに接続後、自動で一覧取得まで行う
      [一覧]        接続済みのメールを一覧表示（添付ありは自動チェック、サイズの大きい順）
      チェックボックスで対象を選択
      [更新]        チェックした添付ファイルを削除して反映

  仕組み上の注意:
    IMAPそのものには「メールの一部分（添付だけ）を書き換える」命令が存在しません。
    そのため実際には
      1) 対象メールを丸ごと取得
      2) 添付ファイルのパートだけ取り除いて再構成
      3) 再構成したメールを同じフォルダにAPPEND（追加）
      4) 元のメールに \Deleted フラグを立てる
      5) 最後にまとめて Expunge（EXPUNGE）して元メールを完全に消す
    という流れで「添付ファイル抜きのメール」に置き換えています。
    （Thunderbirdの「添付ファイルを削除」機能も内部的には同じ考え方です）

  必要なもの:
    ・Delphi XE5（Indy10 は標準搭載）
    ・SSL/TLS接続する場合は libeay32.dll / ssleay32.dll (OpenSSL 32bit) を exe と同じフォルダに置く

  ini構成 (imap_settings.ini):
    [Meta]
    Profiles=プロファイルA;プロファイルB;...   （;区切りの名前一覧）
    LastProfile=プロファイルA

    [Profile:プロファイルA]
    Host=...
    Port=993
    SSL=1
    UserName=...
    Password=...(簡易難読化)
    Folder=INBOX
    MaxCount=200
    DeleteFolder=DeletedAttachments   （添付ファイル付きの元メールの移動先。空欄なら移動せず完全削除）
}

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.StrUtils, System.Variants,
  System.Classes, System.Generics.Collections, System.Generics.Defaults,
  System.UITypes, System.IniFiles, System.IOUtils,
  Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.StdCtrls,
  Vcl.ComCtrls, Vcl.ExtCtrls, Vcl.Clipbrd, SHDocVw,
  IdBaseComponent, IdComponent, IdTCPConnection, IdTCPClient,
  IdExplicitTLSClientServerBase, IdIMAP4, IdMessage, IdAttachment,
  IdAttachmentFile, IdAttachmentMemory, IdText, IdGlobal,
  IdSSLOpenSSL, IdCoderMIME, IdReplyIMAP4, IdCoderHeader, IdMessageClient,
  IdHeaderList,
  // 以下2つは直接使わなくても、MIMEエンコーダ/デコーダを内部登録するために必要
  IdMessageCoder, IdMessageCoderMIME,
  LangUnit;

type
  // 1メール分の作業用情報（一覧表示 & 削除処理の両方で使う）
  TMailEntry = class
  public
    UID: Int64;                // IMAP UID（削除・Expunge・再接続をまたいでも不変）
    Subject: string;
    From: string;
    DateStr: string;
    AttachCount: Integer;
    AttachTotalSize: Int64;
    IsProtected: Boolean;      // ユーザーが「消したくない」と保護指定したメール
    MarkedForDelete: Boolean;  // 「メール削除」列でチェックされている（メールごと削除する対象）
    MarkedForAttachDelete: Boolean; // 「添付削除」列でチェックされている（添付だけ削除する対象）
    Msg: TIdMessage;          // 取得済みメッセージ本体（削除実行時に再利用）
    destructor Destroy; override;
  end;

  { TIdIMAP4には「複数メッセージ分のENVELOPEとBODYSTRUCTUREを1回のFETCHコマンドで
    まとめて取得する」手段が公開されていないため、protectedなAPIを使って自前で
    実装する。1通ずつ通信すると往復回数(レイテンシ)がボトルネックになるため、
    一覧表示はこれで1回の通信にまとめる。 }
  TIdIMAP4Batch = class(TIdIMAP4)
  public
    // UID範囲でENVELOPE/BODYSTRUCTUREをまとめて取得する。
    // シーケンス番号ではなくUIDを使うのは、削除やExpungeで番号がずれても
    // 「前回どこまで検索したか」を安全に記録・再開できるようにするため。
    function RetrieveEnvelopesAndStructures(const AFromUID, AToUID: Int64;
      const AOnMessage: TProc<Int64, TIdMessage, TIdImapMessageParts>): Boolean;

    // Gmailかどうかを判定する（X-GM-EXT-1拡張の有無で判定）
    function IsGmailServer: Boolean;

    { Gmail拡張のX-GM-LABELSでラベルを操作する（\Deleted+EXPUNGEを一切使わない）。
      標準IMAPの「COPYしてから元をDeletedフラグ+EXPUNGE」という消し方だと、
      Gmailの設定次第では複製先のラベルごと元メールがゴミ箱へ落ちてしまうことがある
      （「最後に表示されているIMAPフォルダから削除された」とGmailに解釈されるため）。
      追加と削除を別メソッドに分けているのは、「退避先ラベルを追加→再登録に
      成功したのを確認してから→元のラベルを外す」という安全な順序を保つため
      （COPYしてから安全確認後にDELETEしていた元の流れと同じ考え方）。 }
    function GmailAddLabel(const AUID: Int64; const ALabel: string): Boolean;
    function GmailRemoveLabel(const AUID: Int64; const ALabel: string): Boolean;

    { 指定フォルダがGmailの「ゴミ箱」「迷惑メール」等の特殊フォルダかどうかを、
      LIST応答のspecial-use属性（\Trash, \Junk等）で判定する。
      これらの特殊フォルダはX-GM-LABELSでは正しく操作できず（ラベルとして
      追加してもゴミ箱には移動しない）、通常のCOPYコマンドでしか移動できない。
      逆にユーザーが作った通常のラベルはCOPY+DELETE+EXPUNGEだとゴミ箱へ
      落ちてしまうため、判定して処理方法を切り替える。 }
    function IsSpecialUseMailBox(const AMBName: string): Boolean;

    // 直前のIMAPコマンドの応答コード＋本文を診断用に取り出す（を出さずFalseだけ返すケースで、原因調査のために使う）。
    function GetLastReplyText: string;

    { IndyのAppendMsgには日時(INTERNALDATE)を指定する手段が無く、常に現在時刻に
      なってしまう（元メールの日付を保てず、処理する度に「今日届いた新着メール」
      のように見えてしまう）。IMAPのAPPENDコマンドは本来date-time引数を
      受け付けるため、それを指定できる版を自前で実装する。 }
    function AppendMsgWithDate(const AMBName: string; AMsg: TIdMessage;
      const AFlags: TIdMessageFlagsSet; const AInternalDate: TDateTime): Boolean;

    { Indyの SearchMailBox がGmailで原因不明の[BAD]応答を返すため、
      SUBJECT検索専用の簡易版を自前で実装する（生のSEARCHコマンドを
      直接送り、応答の "* SEARCH n1 n2 ..." 行から番号だけを拾う）。 }
    function SearchBySubject(const ASubject: string): TArray<Integer>;

    { 検索でヒットしたメッセージ番号(複数)のUID/ENVELOPE/BODYSTRUCTUREを
      1回のFETCHコマンドでまとめて取得する（1件ずつ通信すると往復回数の
      ぶんだけ遅くなるため）。番号はシーケンス番号（SEARCHの戻り値）。 }
    function RetrieveEnvelopesAndStructuresBySeqSet(const ASeqNumbers: TArray<Integer>;
      const AOnMessage: TProc<Integer, string, TIdMessage, TIdImapMessageParts>): Boolean;

    { UIDRetrieve/UIDRetrievePeekが失敗した際、「そのUIDのメールがまだ存在するか」を
      判別するための軽量チェック。FLAGSだけをFETCHするので、ENVELOPE/BODYSTRUCTURE
      取得時のようなリテラル絡みのパース不具合を踏みにくい。 }
    function UIDExists(const AMsgUID: string): Boolean;
  end;

  TForm1 = class(TForm)
    pnlConn: TPanel;
    cboProfile: TComboBox;
    btnSaveProfile: TButton;
    btnDeleteProfile: TButton;
    edtHost: TLabeledEdit;
    edtPort: TLabeledEdit;
    chkSSL: TCheckBox;
    edtUser: TLabeledEdit;
    edtPass: TLabeledEdit;
    lblFolder: TLabel;
    cboFolder: TComboBox;
    btnListFolders: TButton;
    edtMaxCount: TLabeledEdit;
    lblDeleteFolder: TLabel;
    cboDeleteFolder: TComboBox;
    btnConnect: TButton;
    LabelDeleteAttachments: TLabel;

    lblStatus: TLabel;
    pList: TPanel;
    memoLog: TMemo;
    lvMails: TListView;
    topPanel: TPanel;
    lblProgress: TLabel;
    btnList: TButton;
    btnUpdate: TButton;
    pbProgress: TProgressBar;
    btnClearCache: TButton;
    btnLanguage: TButton;
    chkAutoConnect: TCheckBox;
    chkAutoList: TCheckBox;
    chkAutoVerify: TCheckBox;
    procedure FormCreate(Sender: TObject);
    procedure DoLanguageChange(Sender: TObject);
    procedure DoAutoConnectClick(Sender: TObject);
    procedure DoAutoListClick(Sender: TObject);
    procedure DoAutoVerifyClick(Sender: TObject);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure DoListMails(Sender: TObject);
    procedure DoProcessSelectedClick(Sender: TObject);
    procedure DoSaveProfileClick(Sender: TObject);
    procedure DoDeleteProfileClick(Sender: TObject);
    procedure DoConnectClick(Sender: TObject);
    procedure DoListFoldersClick(Sender: TObject);
    procedure DoProfileChange(Sender: TObject);
    procedure DoClearCacheClick(Sender: TObject);
    procedure DoColumnClick(Sender: TObject; Column: TListColumn);
    procedure DoCompareItems(Sender: TObject; Item1, Item2: TListItem;
      Data: Integer; var Compare: Integer);
    procedure DoMailsDblClick(Sender: TObject);
    procedure DoMailsMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
  private
    FEntries: TObjectList<TMailEntry>;
    // 更新処理済みのエントリを保持するだけのリスト（一覧からは消さずに残す
    // ため、FEntriesからは外すがオブジェクトの解放はここが引き受ける）。
    FProcessedEntries: TObjectList<TMailEntry>;
    FIMAP4: TIdIMAP4Batch;
    FSSLHandler: TIdSSLIOHandlerSocketOpenSSL;
    IniPath: string;
    LogFilePath: string; // 実行毎に上書きするログファイル（AIによる調査用）
    FSortColumn: Integer;
    FSortAscending: Boolean;
    // IMAP接続(FIMAP4)は同時に1つの処理からしか使えない（SSL/TLSストリームが
    // 壊れるため）。一括削除・単一メール削除・メール削除いずれかがバックグラウンド
    // スレッドで動いている間は、このフラグで他の削除系操作を一切受け付けない。
    FNetworkBusy: Boolean;
    // メール閲覧ダイアログの「添付削除」「メール削除」ボタン用（ダイアログはモーダル
    // 1つしか同時に開かないため、対象を一時的にここへ控えておけば十分）
    FViewerUID: Int64;
    FViewerSubject: string;
    FViewerDlg: TForm;
    FViewerBtnDelAttach: TButton;
    FViewerBtnDelMail: TButton;
    function TryBeginNetworkOp: Boolean;
    procedure EndNetworkOp;
    procedure DoViewerDeleteAttachClick(Sender: TObject);
    procedure DoViewerDeleteMailClick(Sender: TObject);
    // IMAP通信はバックグラウンドスレッドで行うため、VCLコントロールに触る処理は
    // 必ずこれ経由でメインスレッドに戻す（別スレッドから直接触ると不正な描画や
    // クラッシュの原因になる）。
    procedure RunOnMainThread(AProc: TProc);
    // FEntries/lvMailsの更新を伴う場合はこちら（呼び出し元スレッドの処理完了を
    // 待ってから戻る＝FEntriesの整合性が必要な直後の処理からも安全に呼べる）。
    procedure RunOnMainThreadSync(AProc: TProc);
    procedure MarkEntryProcessed(AEntry: TMailEntry);

    procedure Log(const S: string);
    procedure TrimOldLogEntries;
    function ExtractMailHtmlBody(AMsg: TIdMessage): string;
    function ExtractMailPlainBody(AMsg: TIdMessage): string;
    function ExtractMailAttachmentList(AMsg: TIdMessage): string;
    procedure ShowMailContentDialog(AUID: Int64; AMsg: TIdMessage; const ASubject: string);
    procedure PrepareDeleteFolder(const ADeleteFolder: string; out AIsGmail, AIsSpecialUseFolder: Boolean);
    function MoveOrDeleteOriginal(AUID: Int64; const ADeleteFolder: string;
      AIsGmail, AIsSpecialUseFolder: Boolean): Boolean;
    function FindEntryByUID(AUID: Int64): TMailEntry;
    // 「4. 選択した項目を処理」ボタン用：添付削除対象・メール削除対象をそれぞれ
    // 処理する。どちらもバックグラウンドスレッドから呼ばれる想定（imapは呼び出し元
    // が接続・SelectMailBox済みのものを渡す）。
    procedure ProcessAttachDeleteTargets(AImap: TIdIMAP4Batch; ATargets: TList<TMailEntry>;
      const ADeleteFolder: string; AIsGmail, AIsSpecialUseFolder, AAutoVerify: Boolean;
      out ATotalMails, ATotalRemoved: Integer);
    procedure ProcessMailDeleteTargets(AImap: TIdIMAP4Batch; ATargets: TList<TMailEntry>;
      const ADeleteFolder: string; AIsGmail, AIsSpecialUseFolder: Boolean;
      out ATotalDeleted: Integer);
    procedure RemoveAttachmentsForSingleMail(AUID: Int64; const ASubject: string);
    procedure DeleteMailEntirely(AUID: Int64; const ASubject: string);
    // メール本文取得中の進捗(ダウンロード済みバイト数)をプログレスバーに反映する
    procedure DoFetchWorkBegin(ASender: TObject; AWorkMode: TWorkMode; AWorkCountMax: Int64);
    procedure DoFetchWork(ASender: TObject; AWorkMode: TWorkMode; AWorkCount: Int64);
    procedure DoFetchWorkEnd(ASender: TObject; AWorkMode: TWorkMode);
    // 複数メールを同時に削除しようとした最初の1回だけ、追加の警告を出す。
    // 「見せたかどうか」はimap_settings.iniの[Meta]WarnedBulkDeleteで管理する
    // （iniを消せば再度出るが、それはユーザーの選択として許容する）。
    function ConfirmBulkWarningIfNeeded(ACount: Integer): Boolean;
    procedure EnsureConnected;
    // 応答の解析エラー等で接続がずれた可能性がある場合、残っている未読データを
    // 破棄して次のコマンドに影響が及ばないようにする（そのまま放置すると、
    // ズレたデータを次のコマンドが誤って読んでしまい、長時間ハングすることがある）。
    procedure ClearIOBuffer;
    procedure ClearEntries;
    procedure UpdateProgress(ACurrent, AMax: Integer; const AText: string);
    procedure ResetProgress;
    function StripAttachmentsFromMessage(AMsg: TIdMessage; out RemovedCount: Integer): Boolean;

    function ScanCacheFileName: string;
    function VerifySkipFileName: string;
    function IsUIDInVerifySkipList(AUID: Int64): Boolean;
    procedure AddUIDToVerifySkipList(AUID: Int64);
    function ProtectedFileName: string;
    function LoadProtectedUIDs: TDictionary<Int64, Boolean>;
    procedure SetUIDProtected(AUID: Int64; AProtect: Boolean);
    function ProtectMarkText(AProtected: Boolean): string;
    function DeleteMailMarkText(AMarked: Boolean): string;
    function AttachDeleteMarkText(AMarked: Boolean): string;
    // 一覧の「保護」「メール削除」列がクリックされたとき、その行のON/OFFを切り替える
    procedure ToggleMarkColumnAtPoint(X, Y: Integer);
    procedure RemoveEntryFromList(AEntry: TMailEntry);
    procedure LoadScanCache(out ALastUID: Int64);
    procedure SaveScanCache(const ALastUID: Int64);
    function PeekLastScannedUID: Int64;

    // 件名検証: 指定フォルダ内を件名(部分一致)で検索し、見つかった各メールの
    // UID・日付・添付有無をログへ出力する（削除/退避処理が正しく行われたかの確認用）。
    procedure VerifySubjectInFolder(const AFolder, ASubject: string);

    function SimpleObfuscate(const S: string): string;
    function SimpleDeobfuscate(const S: string): string;

    procedure RefreshProfileList(const ASelectName: string = '');
    function ProfileSectionName(const AName: string): string;
    procedure LoadProfileFields(const AName: string);
    procedure SaveProfileFields(const AName: string);
    procedure SaveLastProfile(const AName: string);

    // Host/Port/User/Pass の内容でログインだけ行う（フォルダ選択はしない）。
    // 未接続なら接続し、失敗時は例外を投げる。
    procedure EnsureLoggedIn;
    function ExtractMailboxName(const ALine: string): string;

    function FolderName: string;
    function MaxCountText: string;
    function DeleteFolderName: string;

    // 言語ファイル(lang_ja.ini/lang_en.ini)を読み込み直し、画面上の固定文言を
    // 差し替える。ログや確認メッセージ等の動的な文言はT()を都度呼ぶだけでよい。
    procedure ApplyLanguage;
  end;

var
  Form1: TForm1;

implementation

{$R *.dfm}

const
  ProfileSep = ';';

{ TMailEntry }

destructor TMailEntry.Destroy;
begin
  Msg.Free;
  inherited;
end;

{ Indyのバージョンによっては TIdAttachment に公開の Size プロパティが無いため、
  どのバージョンでも必ず存在する PrepareTempStream/FinishTempStream
  （添付の実体をストリームとして取り出す仕組み）経由でサイズを取得する。 }
function GetAttachmentSize(AAttachment: TIdAttachment): Int64;
var
  strm: TStream;
begin
  Result := 0;
  if AAttachment = nil then Exit;
  try
    strm := AAttachment.PrepareTempStream;
    try
      if Assigned(strm) then
        Result := strm.Size;
    finally
      AAttachment.FinishTempStream;
    end;
  except
    Result := 0;
  end;
end;

{ TIdIMAPLineStruct.MessageNumber / IMAPValue は protected なので、別クラス
  (TIdIMAP4Batch)からは直接読めない。クラスヘルパーはprotectedメンバーに
  アクセスできる特例があるため、それを利用して読み出し用メソッドを追加する。 }
type
  TIdIMAPLineStructHelper = class helper for TIdIMAPLineStruct
    function GetIMAPValue: string;
    function GetUID: string;
    function GetMessageNumber: string;
  end;

function TIdIMAPLineStructHelper.GetIMAPValue: string;
begin
  Result := IMAPValue;
end;

function TIdIMAPLineStructHelper.GetMessageNumber: string;
begin
  Result := MessageNumber;
end;

function TIdIMAPLineStructHelper.GetUID: string;
begin
  Result := UID;
end;

function TIdIMAP4Batch.RetrieveEnvelopesAndStructures(const AFromUID, AToUID: Int64;
  const AOnMessage: TProc<Int64, TIdMessage, TIdImapMessageParts>): Boolean;
var
  Ln: Integer;
  LLine: string;
  LUID: Int64;
  LMsg: TIdMessage;
  LParts: TIdImapMessageParts;
begin
  Result := False;
  CheckConnectionState(csSelected);
  SendCmd(NewCmdCounter,
    'UID FETCH ' + IntToStr(AFromUID) + ':' + IntToStr(AToUID) + ' (UID ENVELOPE BODYSTRUCTURE)', {Do not Localize}
    ['FETCH']); {Do not Localize}
  if LastCmdResult.Code <> IMAP_OK then Exit;

  for Ln := 0 to LastCmdResult.Text.Count - 1 do begin
    LLine := LastCmdResult.Text[Ln];
    LUID := 0;

    LMsg := TIdMessage.Create(nil);
    LParts := TIdImapMessageParts.Create(nil);
    try
      if ParseLastCmdResult(LLine, 'FETCH', ['ENVELOPE']) then {Do not Localize}
      begin
        LUID := System.SysUtils.StrToInt64Def(FLineStruct.GetUID, 0);
        ParseEnvelopeResult(LMsg, FLineStruct.GetIMAPValue);
      end;
      if ParseLastCmdResult(LLine, 'FETCH', ['BODYSTRUCTURE']) then {Do not Localize}
      begin
        if LUID = 0 then
          LUID := System.SysUtils.StrToInt64Def(FLineStruct.GetUID, 0);
        ParseBodyStructureResult(FLineStruct.GetIMAPValue, nil, LParts);
      end;

      if LUID > 0 then
        AOnMessage(LUID, LMsg, LParts);
    finally
      LMsg.Free;
      LParts.Free;
    end;
  end;
  Result := True;
end;

function TIdIMAP4Batch.IsGmailServer: Boolean;
var
  caps: TStringList;
  s: string;
begin
  Result := False;
  caps := TStringList.Create;
  try
    if Capability(caps) then
      for s in caps do
        if SameText(s, 'X-GM-EXT-1') then begin
          Result := True;
          Break;
        end;
  finally
    caps.Free;
  end;
end;

function TIdIMAP4Batch.GmailAddLabel(const AUID: Int64; const ALabel: string): Boolean;
begin
  CheckConnectionState(csSelected);
  SendCmd(NewCmdCounter,
    'UID STORE ' + IntToStr(AUID) + ' +X-GM-LABELS ("' + DoMUTFEncode(ALabel) + '")', {Do not Localize}
    ['STORE']); {Do not Localize}
  Result := LastCmdResult.Code = IMAP_OK;
end;

function TIdIMAP4Batch.GmailRemoveLabel(const AUID: Int64; const ALabel: string): Boolean;
begin
  CheckConnectionState(csSelected);
  SendCmd(NewCmdCounter,
    'UID STORE ' + IntToStr(AUID) + ' -X-GM-LABELS ("' + DoMUTFEncode(ALabel) + '")', {Do not Localize}
    ['STORE']); {Do not Localize}
  Result := LastCmdResult.Code = IMAP_OK;
end;

function TIdIMAP4Batch.GetLastReplyText: string;
begin
  Result := '[' + LastCmdResult.Code + '] ' + StringReplace(Trim(LastCmdResult.Text.Text), #13#10, ' / ', [rfReplaceAll]);
end;

{ IMAPのAPPEND date-time引数の形式（例: "01-Jan-2024 01:02:03 +0900"）を組み立てる。
  Indy内部の同種のヘルパーはunit外から使えないため、自前で用意する。 }
function BuildIMAPDateTimeLiteral(const ADateTime: TDateTime): string;
const
  MonthAbbr: array[1..12] of string = ('Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec');
var
  wDay, wMonth, wYear: Word;
  tzInfo: TTimeZoneInformation;
  biasMinutes: Integer;
  sign: string;
begin
  DecodeDate(ADateTime, wYear, wMonth, wDay);

  case GetTimeZoneInformation(tzInfo) of
    TIME_ZONE_ID_STANDARD: biasMinutes := tzInfo.Bias + tzInfo.StandardBias;
    TIME_ZONE_ID_DAYLIGHT: biasMinutes := tzInfo.Bias + tzInfo.DaylightBias;
  else
    biasMinutes := tzInfo.Bias;
  end;
  // Biasは「UTC = ローカル時刻 + Bias分」なので、タイムゾーン表記はその符号を反転させたもの
  if -biasMinutes >= 0 then
    sign := '+'
  else
    sign := '-';

  Result := Format('"%.2d-%s-%.4d %s %s%.2d%.2d"',
    [wDay, MonthAbbr[wMonth], wYear, FormatDateTime('hh":"nn":"ss', ADateTime),
     sign, Abs(biasMinutes) div 60, Abs(biasMinutes) mod 60]);
end;

function TIdIMAP4Batch.AppendMsgWithDate(const AMBName: string; AMsg: TIdMessage;
  const AFlags: TIdMessageFlagsSet; const AInternalDate: TDateTime): Boolean;
var
  LFlags, LMsgLiteral, LDateLiteral, LOrigMsgId: string;
  LUseNonSyncLiteral: Boolean;
  Ln: Integer;
  LCmd: string;
  LLength: Int64;
  LHeadersToSend: TIdHeaderList;
  LHeadersAsString: string;
  LHeadersAsBytes: TIdBytes;
  LStream: TStream;
  LMsgClient: TIdMessageClient;
  LMsgIO: TIdIOHandlerStreamMsg;
begin
  Result := False;
  CheckConnectionState([csAuthenticated, csSelected]);
  if Length(AMBName) = 0 then Exit;

  // TIdMessageはヘッダー生成時にMessage-IDを空にしてしまう（新規送信メールを
  // 発行する想定の作りのため）。今回は既存メールの複製なので、元のMessage-IDを
  // 控えておいて後で復元し、返信・スレッドの紐付けが切れないようにする。
  LOrigMsgId := AMsg.MsgId;

  LFlags := MessageFlagSetToStr(AFlags);
  if LFlags <> '' then
    LFlags := '(' + LFlags + ')';

  LDateLiteral := BuildIMAPDateTimeLiteral(AInternalDate);

  LStream := TMemoryStream.Create;
  try
    // Indy標準のSaveToStream()はSMTPのdot-transparencyでエスケープしてしまい
    // IMAPには不適切なため、AppendMsg内部と同じワークアラウンドを使う。
    LMsgClient := TIdMessageClient.Create(nil);
    try
      LMsgIO := TIdIOHandlerStreamMsg.Create(nil, nil, LStream);
      try
        LMsgIO.FreeStreams := False;
        LMsgIO.UnescapeLines := True;
        LMsgClient.IOHandler := LMsgIO;
        try
          LMsgClient.SendMsg(AMsg, False);
        finally
          LMsgClient.IOHandler := nil;
        end;
      finally
        LMsgIO.Free;
      end;
    finally
      LMsgClient.Free;
    end;

    LStream.Position := 0;
    LHeadersToSend := AMsg.LastGeneratedHeaders;
    if LOrigMsgId <> '' then
      LHeadersToSend.Values['Message-Id'] := LOrigMsgId; {Do not Localize}
    LHeadersAsString := '';
    for Ln := 0 to Pred(LHeadersToSend.Count) do
      LHeadersAsString := LHeadersAsString + LHeadersToSend[Ln] + EOL;
    LHeadersAsBytes := ToBytes(LHeadersAsString + EOL);
    LHeadersAsString := '';

    repeat until Length(ReadLnFromStream(LStream)) = 0;
    LLength := Length(LHeadersAsBytes) + (LStream.Size - LStream.Position);

    LUseNonSyncLiteral := IsCapabilityListed('LITERAL+'); {Do not Localize}
    if LUseNonSyncLiteral then
      LMsgLiteral := '{' + IntToStr(LLength) + '+}' {Do not Localize}
    else
      LMsgLiteral := '{' + IntToStr(LLength) + '}'; {Do not Localize}

    LCmd := 'APPEND "' + DoMUTFEncode(AMBName) + '" '; {Do not Localize}
    if LFlags <> '' then
      LCmd := LCmd + LFlags + ' ';
    LCmd := LCmd + LDateLiteral + ' ' + LMsgLiteral;

    if LUseNonSyncLiteral then begin
      IOHandler.WriteLn(NewCmdCounter + ' ' + LCmd);
    end else begin
      SendCmd(NewCmdCounter, LCmd, []);
      if LastCmdResult.Code <> IMAP_CONT then Exit;
    end;

    IOHandler.Write(LHeadersAsBytes);
    IOHandler.Write(LStream, -1, False);
    IOHandler.WriteLn;
    if GetInternalResponse(LastCmdCounter, ['APPEND'], False) = IMAP_OK then {Do not Localize}
      Result := True;
  finally
    LStream.Free;
  end;
end;

function TIdIMAP4Batch.SearchBySubject(const ASubject: string): TArray<Integer>;
var
  Ln: Integer;
  LLine, LNumStr, LQuoted: string;
  LParts: TArray<string>;
  LResult: TList<Integer>;
  LNum: Integer;
begin
  SetLength(Result, 0);
  CheckConnectionState(csSelected);

  LQuoted := StringReplace(ASubject, '\', '\\', [rfReplaceAll]);
  LQuoted := StringReplace(LQuoted, '"', '\"', [rfReplaceAll]);

  SendCmd(NewCmdCounter, 'SEARCH SUBJECT "' + LQuoted + '"', ['SEARCH']); {Do not Localize}
  if LastCmdResult.Code <> IMAP_OK then Exit;

  LResult := TList<Integer>.Create;
  try
    for Ln := 0 to LastCmdResult.Text.Count - 1 do begin
      LLine := Trim(LastCmdResult.Text[Ln]);
      // SendCmdが未タグ行の先頭"* "を既に取り除いて格納する場合があるため、
      // 両方の形式（"* SEARCH ..." と "SEARCH ..."）を受け付ける。
      if Copy(LLine, 1, 2) = '* ' then {Do not Localize}
        LLine := Trim(Copy(LLine, 3, MaxInt));
      if Copy(LLine, 1, 6) = 'SEARCH' then begin {Do not Localize}
        LParts := Trim(Copy(LLine, 7, MaxInt)).Split([' ']);
        for LNumStr in LParts do
          if TryStrToInt(Trim(LNumStr), LNum) then
            LResult.Add(LNum);
      end;
    end;
    Result := LResult.ToArray;
  finally
    LResult.Free;
  end;
end;

function TIdIMAP4Batch.RetrieveEnvelopesAndStructuresBySeqSet(const ASeqNumbers: TArray<Integer>;
  const AOnMessage: TProc<Integer, string, TIdMessage, TIdImapMessageParts>): Boolean;
var
  i, Ln, LSeqNum: Integer;
  LSetStr, LLine, LUID: string;
  LMsg: TIdMessage;
  LParts: TIdImapMessageParts;
begin
  Result := False;
  if Length(ASeqNumbers) = 0 then Exit;
  CheckConnectionState(csSelected);

  LSetStr := '';
  for i := 0 to High(ASeqNumbers) do begin
    if LSetStr <> '' then
      LSetStr := LSetStr + ','; {Do not Localize}
    LSetStr := LSetStr + IntToStr(ASeqNumbers[i]);
  end;

  SendCmd(NewCmdCounter, 'FETCH ' + LSetStr + ' (UID ENVELOPE BODYSTRUCTURE)', ['FETCH']); {Do not Localize}
  if LastCmdResult.Code <> IMAP_OK then Exit;

  for Ln := 0 to LastCmdResult.Text.Count - 1 do begin
    LLine := LastCmdResult.Text[Ln];
    LSeqNum := 0;
    LUID := '';

    LMsg := TIdMessage.Create(nil);
    LParts := TIdImapMessageParts.Create(nil);
    try
      if ParseLastCmdResult(LLine, 'FETCH', ['ENVELOPE']) then begin {Do not Localize}
        LSeqNum := System.SysUtils.StrToIntDef(FLineStruct.GetMessageNumber, 0);
        LUID := FLineStruct.GetUID;
        ParseEnvelopeResult(LMsg, FLineStruct.GetIMAPValue);
      end;
      if ParseLastCmdResult(LLine, 'FETCH', ['BODYSTRUCTURE']) then begin {Do not Localize}
        if LSeqNum = 0 then
          LSeqNum := System.SysUtils.StrToIntDef(FLineStruct.GetMessageNumber, 0);
        if LUID = '' then
          LUID := FLineStruct.GetUID;
        ParseBodyStructureResult(FLineStruct.GetIMAPValue, nil, LParts);
      end;

      if LSeqNum > 0 then
        AOnMessage(LSeqNum, LUID, LMsg, LParts);
    finally
      LMsg.Free;
      LParts.Free;
    end;
  end;
  Result := True;
end;

function TIdIMAP4Batch.UIDExists(const AMsgUID: string): Boolean;
begin
  Result := False;
  CheckConnectionState(csSelected);
  SendCmd(NewCmdCounter, 'UID FETCH ' + AMsgUID + ' (FLAGS)', ['FETCH']); {Do not Localize}
  if LastCmdResult.Code = IMAP_OK then
    Result := LastCmdResult.Text.Count > 0; // データ行が1つも無ければ既に存在しない
end;

function TIdIMAP4Batch.IsSpecialUseMailBox(const AMBName: string): Boolean;
var
  Ln: Integer;
  LLine: string;
begin
  Result := False;
  CheckConnectionState([csAuthenticated, csSelected]);
  SendCmd(NewCmdCounter, 'LIST "" "' + DoMUTFEncode(AMBName) + '"', ['LIST']); {Do not Localize}
  if LastCmdResult.Code <> IMAP_OK then Exit;
  for Ln := 0 to LastCmdResult.Text.Count - 1 do begin
    LLine := UpperCase(LastCmdResult.Text[Ln]);
    if (Pos('\TRASH', LLine) > 0) or (Pos('\JUNK', LLine) > 0) then begin
      Result := True;
      Break;
    end;
  end;
end;

{ TForm1 }

procedure TForm1.FormCreate(Sender: TObject);
var
  langIni: TIniFile;
  langCode: string;
  autoConnect: Boolean;
  autoList: Boolean;
  autoVerify: Boolean;
begin
  FEntries := TObjectList<TMailEntry>.Create(True);
  FProcessedEntries := TObjectList<TMailEntry>.Create(True);
  FSortColumn := -1;
  FSortAscending := True;

  IniPath := ExtractFilePath(ParamStr(0)) + 'imap_settings.ini';
  LogFilePath := ExtractFilePath(ParamStr(0)) + 'app.log';
  // 起動の度に全消去はせず、3か月より古い行だけを間引く（それ以降は追記していく）
  TrimOldLogEntries;

  // 前回保存された表示言語を読み込む（未設定ならOSの既定言語から日英を推測）
  langCode := 'ja';
  autoConnect := False; // 起動時の自動接続は明示的にONにするまでデフォルトでオフ
  autoList := True; // 接続後の自動一覧取得はデフォルトでオン
  autoVerify := True; // 削除ごとの自動検証はデフォルトでオン
  if FileExists(IniPath) then begin
    langIni := TIniFile.Create(IniPath);
    try
      langCode := langIni.ReadString('Meta', 'Language', ''); {Do not Localize}
      autoConnect := langIni.ReadBool('Meta', 'AutoConnect', False); {Do not Localize}
      autoList := langIni.ReadBool('Meta', 'AutoList', True); {Do not Localize}
      autoVerify := langIni.ReadBool('Meta', 'AutoVerify', True); {Do not Localize}
    finally
      langIni.Free;
    end;
  end;
  chkAutoConnect.Checked := autoConnect;
  chkAutoList.Checked := autoList;
  chkAutoVerify.Checked := autoVerify;
  if langCode = '' then begin
    if SysLocale.PriLangID = LANG_JAPANESE then
      langCode := 'ja'
    else
      langCode := 'en';
  end;

  FIMAP4 := TIdIMAP4Batch.Create(Self);
  FSSLHandler := TIdSSLIOHandlerSocketOpenSSL.Create(Self);
  FSSLHandler.SSLOptions.Method := sslvTLSv1_2;
  FSSLHandler.SSLOptions.Mode := sslmClient;

  SetLanguage(langCode);
  ApplyLanguage;

  RefreshProfileList;

  // 前回使ったプロファイルがあれば自動で読み込む（接続は「起動時に自動接続する」が
  // ONのときだけ行う。デフォルトはオフ）
  if cboProfile.Items.Count > 0 then begin
    if cboProfile.ItemIndex < 0 then
      cboProfile.ItemIndex := 0;
    LoadProfileFields(cboProfile.Text);

    if chkAutoConnect.Checked then
      btnConnect.Click;
  end
  else begin
    // プロファイルが1件も無い（ini未作成 or 空）場合、利用者の大半がGmailのため
    // Gmail接続用の初期値を入れておく。ユーザー名/パスワードだけ入力すれば
    // 「この内容で登録」で保存できる。
    cboProfile.Text := 'Gmail';
    edtHost.Text := 'imap.gmail.com';
    edtPort.Text := '993';
    chkSSL.Checked := True;
    cboFolder.Text := 'INBOX';
    edtMaxCount.Text := '50';
    cboDeleteFolder.Text := 'DeletedAttachments';
  end;
end;

{ lang_ja.ini / lang_en.ini から読み込んだ文言で、画面上の固定キャプション
  （ボタン・ラベル・列見出し等）を差し替える。ログやメッセージ文言は
  呼び出し側でT()をその都度呼べば良いのでここでは扱わない。 }
procedure TForm1.ApplyLanguage;
begin
  Caption := T('form.caption');
  lblFolder.Caption := T('lbl.folder');
  lblDeleteFolder.Caption := T('lbl.deleteFolder');
  LabelDeleteAttachments.Caption := T('lbl.deleteAttachments');
  if not FIMAP4.Connected then
    lblStatus.Caption := T('lbl.status');
  btnSaveProfile.Caption := T('btn.saveProfile');
  btnDeleteProfile.Caption := T('btn.deleteProfile');
  btnListFolders.Caption := T('btn.listFolders');
  btnConnect.Caption := T('btn.connect');
  btnList.Caption := T('btn.list');
  btnUpdate.Caption := T('btn.processSelected');
  btnClearCache.Caption := T('btn.clearCache');
  edtMaxCount.EditLabel.Caption := T('edt.maxCountLabel');
  chkAutoConnect.Caption := T('chk.autoConnect');
  chkAutoList.Caption := T('chk.autoList');
  chkAutoVerify.Caption := T('chk.autoVerify');

  if SameText(CurrentLangCode, 'en') then
    btnLanguage.Caption := '日本語' {Do not Localize}
  else
    btnLanguage.Caption := 'English'; {Do not Localize}

  // 列順: 添付削除(標準チェックボックス), メール削除, 保護, 日付, 差出人, 件名, 添付数, 添付合計サイズ
  if lvMails.Columns.Count >= 8 then begin
    lvMails.Columns[0].Caption := T('col.attachDelete');
    lvMails.Columns[1].Caption := T('col.deleteMail');
    lvMails.Columns[2].Caption := T('col.protect');
    lvMails.Columns[3].Caption := T('col.date');
    lvMails.Columns[4].Caption := T('col.from');
    lvMails.Columns[5].Caption := T('col.subject');
    lvMails.Columns[6].Caption := T('col.attachCount');
    lvMails.Columns[7].Caption := T('col.attachSize');
  end;
end;

procedure TForm1.DoLanguageChange(Sender: TObject);
var
  code: string;
  ini: TIniFile;
begin
  if SameText(CurrentLangCode, 'en') then
    code := 'ja'
  else
    code := 'en';
  SetLanguage(code);
  ApplyLanguage;

  if IniPath <> '' then begin
    ini := TIniFile.Create(IniPath);
    try
      ini.WriteString('Meta', 'Language', code); {Do not Localize}
    finally
      ini.Free;
    end;
  end;
end;

procedure TForm1.DoAutoConnectClick(Sender: TObject);
var
  ini: TIniFile;
begin
  if IniPath <> '' then begin
    ini := TIniFile.Create(IniPath);
    try
      ini.WriteBool('Meta', 'AutoConnect', chkAutoConnect.Checked); {Do not Localize}
    finally
      ini.Free;
    end;
  end;
end;

procedure TForm1.DoAutoListClick(Sender: TObject);
var
  ini: TIniFile;
begin
  if IniPath <> '' then begin
    ini := TIniFile.Create(IniPath);
    try
      ini.WriteBool('Meta', 'AutoList', chkAutoList.Checked); {Do not Localize}
    finally
      ini.Free;
    end;
  end;
end;

procedure TForm1.DoAutoVerifyClick(Sender: TObject);
var
  ini: TIniFile;
begin
  if IniPath <> '' then begin
    ini := TIniFile.Create(IniPath);
    try
      ini.WriteBool('Meta', 'AutoVerify', chkAutoVerify.Checked); {Do not Localize}
    finally
      ini.Free;
    end;
  end;
end;

{ FIMAP4への同時アクセスを防ぐためのロック。取得できなければFalseを返すので、
  呼び出し側は「他の処理が実行中です」と表示してExitする。 }
function TForm1.TryBeginNetworkOp: Boolean;
begin
  Result := not FNetworkBusy;
  if Result then
    FNetworkBusy := True
  else
    ShowMessage(T('msg.networkBusy'));
end;

procedure TForm1.EndNetworkOp;
begin
  FNetworkBusy := False;
end;

function TForm1.ConfirmBulkWarningIfNeeded(ACount: Integer): Boolean;
var
  ini: TIniFile;
  warned: Boolean;
begin
  Result := True;
  if ACount <= 1 then Exit;

  warned := False;
  if FileExists(IniPath) then begin
    ini := TIniFile.Create(IniPath);
    try
      warned := ini.ReadBool('Meta', 'WarnedBulkDelete', False); {Do not Localize}
    finally
      ini.Free;
    end;
  end;
  if warned then Exit;

  if MessageDlg(Format(T('msg.bulkWarnFirstTime'), [ACount]), mtWarning, [mbOK, mbCancel], 0) <> mrOk then begin
    Result := False;
    Exit;
  end;

  if IniPath <> '' then begin
    ini := TIniFile.Create(IniPath);
    try
      ini.WriteBool('Meta', 'WarnedBulkDelete', True); {Do not Localize}
    finally
      ini.Free;
    end;
  end;
end;

procedure TForm1.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  try
    if Assigned(FIMAP4) and FIMAP4.Connected then
      FIMAP4.Disconnect;
  except
    // 終了時なので握りつぶす
  end;
  FEntries.Free;
  FProcessedEntries.Free;
end;

{ ログ1行目の先頭にある日付(yyyy/mm/dd)を読み取る。旧形式（時刻のみ）など
  読み取れない行はFalseを返す。 }
function TryParseLogLineDate(const ALine: string; out ADate: TDateTime): Boolean;
var
  y, m, d: Integer;
begin
  Result := False;
  if Length(ALine) < 10 then Exit;
  y := StrToIntDef(Copy(ALine, 1, 4), 0);
  m := StrToIntDef(Copy(ALine, 6, 2), 0);
  d := StrToIntDef(Copy(ALine, 9, 2), 0);
  if (y = 0) or (m = 0) or (d = 0) then Exit;
  try
    ADate := EncodeDate(y, m, d);
    Result := True;
  except
    Result := False;
  end;
end;

{ ログファイルのうち3か月より古い行を間引く。日付が読み取れない行（旧形式など）
  も古いものとみなして落とす。ファイルが無い/壊れている場合は何もしない。 }
procedure TForm1.TrimOldLogEntries;
const
  MaxAgeDays = 92; // 約3か月
var
  sl, kept: TStringList;
  i: Integer;
  lineDate: TDateTime;
  cutoff: TDateTime;
begin
  if (LogFilePath = '') or (not FileExists(LogFilePath)) then Exit;

  cutoff := Now - MaxAgeDays;
  sl := TStringList.Create;
  kept := TStringList.Create;
  try
    try
      sl.LoadFromFile(LogFilePath, TEncoding.UTF8);
    except
      Exit; // 読み込めない場合は触らずそのままにしておく
    end;

    for i := 0 to sl.Count - 1 do begin
      if TryParseLogLineDate(sl[i], lineDate) and (lineDate >= cutoff) then
        kept.Add(sl[i]);
    end;

    if kept.Count <> sl.Count then begin
      try
        kept.SaveToFile(LogFilePath, TEncoding.UTF8);
      except
        // 書き込み失敗は致命的ではないので無視する
      end;
    end;
  finally
    sl.Free;
    kept.Free;
  end;
end;

{ ワーカースレッドから呼ばれた場合はTThread.Queueでメインスレッドへ回す。
  メインスレッドから呼ばれた場合はそのまま実行する（余計な遅延を避ける）。 }
procedure TForm1.RunOnMainThread(AProc: TProc);
begin
  if TThread.CurrentThread.ThreadID = MainThreadID then
    AProc()
  else
    TThread.Queue(nil, procedure begin AProc(); end);
end;

procedure TForm1.RunOnMainThreadSync(AProc: TProc);
begin
  if TThread.CurrentThread.ThreadID = MainThreadID then
    AProc()
  else
    TThread.Synchronize(nil, procedure begin AProc(); end);
end;

{ 一括更新処理中、1通の退避が完了するたびに呼ぶ。FEntries/lvMailsの更新を
  同期的に(呼び出し元がワーカースレッドならブロックして)行うことで、直後の
  SaveScanCacheがFEntriesの最新状態を確実に読めるようにする。 }
procedure TForm1.MarkEntryProcessed(AEntry: TMailEntry);
begin
  RunOnMainThreadSync(
    procedure
    var
      j: Integer;
    begin
      FEntries.Extract(AEntry);
      FProcessedEntries.Add(AEntry);
      for j := 0 to lvMails.Items.Count - 1 do begin
        if lvMails.Items[j].Data = AEntry then begin
          // 件名列(SubItems[4]: 保護/メール削除/日付/差出人 の次)に[済]を付ける
          lvMails.Items[j].SubItems[4] := T('note.processedPrefix') + ' ' + lvMails.Items[j].SubItems[4];
          AEntry.MarkedForAttachDelete := False;
          lvMails.Items[j].Caption := AttachDeleteMarkText(False);
          Break;
        end;
      end;
    end);
end;

procedure TForm1.Log(const S: string);
begin
  RunOnMainThread(
    procedure
    var
      line: string;
      f: TextFile;
    begin
      line := FormatDateTime('yyyy/mm/dd hh:nn:ss', Now) + '  ' + S;
      memoLog.Lines.Add(line);

      // 画面のログとは別に、実行毎に上書きされるファイルにも書き出す。
      // AIエージェント等がこのファイルを直接読んで調査できるようにするため。
      if LogFilePath <> '' then begin
        try
          AssignFile(f, LogFilePath);
          {$I-}
          Append(f);
          if IOResult <> 0 then
            Rewrite(f);
          {$I+}
          try
            WriteLn(f, line);
          finally
            CloseFile(f);
          end;
        except
          // ログファイルへの書き込み失敗は致命的ではないので無視する
        end;
      end;
    end);
end;

{ 時間のかかるループ処理の途中経過を、下部のプログレスバー/ラベルに反映する。
  IMAP通信は同期処理でメインスレッドをブロックするため、ProcessMessagesで
  都度描画を更新し「フリーズしたように見える」のを防ぐ。 }
procedure TForm1.UpdateProgress(ACurrent, AMax: Integer; const AText: string);
var
  isMainThread: Boolean;
begin
  isMainThread := TThread.CurrentThread.ThreadID = MainThreadID;
  RunOnMainThread(
    procedure
    begin
      if AMax <= 0 then begin
        pbProgress.Max := 100;
        pbProgress.Position := 0;
      end
      else begin
        pbProgress.Max := AMax;
        if ACurrent > AMax then
          pbProgress.Position := AMax
        else
          pbProgress.Position := ACurrent;
      end;
      lblProgress.Caption := AText;
      // ワーカースレッド側はTThread.Queueで非同期に反映されるので、ここでの
      // ProcessMessagesはメインスレッドから直接呼ばれた場合にのみ意味を持つ
      // （フリーズして見えるのを防ぐための即時描画更新）。
      if isMainThread then
        Application.ProcessMessages;
    end);
end;

procedure TForm1.ResetProgress;
begin
  RunOnMainThread(
    procedure
    begin
      pbProgress.Position := 0;
      lblProgress.Caption := '';
    end);
end;

procedure TForm1.EnsureConnected;
begin
  if (FIMAP4 = nil) or (not FIMAP4.Connected) then
    raise Exception.Create(T('msg.notConnected'));
end;

procedure TForm1.ClearIOBuffer;
begin
  try
    if Assigned(FIMAP4) and FIMAP4.Connected and Assigned(FIMAP4.IOHandler) then begin
      repeat
        FIMAP4.IOHandler.InputBuffer.Clear;
        Application.ProcessMessages;
      until not FIMAP4.IOHandler.CheckForDataOnSource(50);
    end;
  except
    // クリア自体の失敗は無視してよい
  end;
end;

procedure TForm1.ClearEntries;
begin
  FEntries.Clear;
  FProcessedEntries.Clear;
  lvMails.Items.Clear;
end;

{ 列見出しクリックで並び替え。同じ列を続けてクリックすると昇順/降順を反転する。 }
procedure TForm1.DoColumnClick(Sender: TObject; Column: TListColumn);
begin
  if FSortColumn = Column.Index then
    FSortAscending := not FSortAscending
  else begin
    FSortColumn := Column.Index;
    FSortAscending := True;
  end;
  lvMails.CustomSort(nil, FSortColumn);
end;

procedure TForm1.DoCompareItems(Sender: TObject; Item1, Item2: TListItem;
  Data: Integer; var Compare: Integer);
var
  e1, e2: TMailEntry;
begin
  e1 := TMailEntry(Item1.Data);
  e2 := TMailEntry(Item2.Data);
  // 列順: 添付削除(標準チェックボックス), メール削除, 保護, 日付, 差出人, 件名, 添付数, 添付合計サイズ
  case Data of
    0: Compare := Ord(e1.MarkedForAttachDelete) - Ord(e2.MarkedForAttachDelete);
    1: Compare := Ord(e1.MarkedForDelete) - Ord(e2.MarkedForDelete);
    2: Compare := Ord(e1.IsProtected) - Ord(e2.IsProtected);
    3: Compare := CompareText(Item1.SubItems[2], Item2.SubItems[2]); // 日付（yyyy/mm/dd hh:nn形式なので文字列比較で正しい順になる）
    4: Compare := CompareText(e1.From, e2.From);
    5: Compare := CompareText(e1.Subject, e2.Subject);
    6: Compare := e1.AttachCount - e2.AttachCount;
    7: // 添付合計サイズ
      begin
        if e1.AttachTotalSize < e2.AttachTotalSize then Compare := -1
        else if e1.AttachTotalSize > e2.AttachTotalSize then Compare := 1
        else Compare := 0;
      end;
  else
    Compare := 0;
  end;
  if not FSortAscending then
    Compare := -Compare;
end;

{ メッセージ中のtext/htmlパートを探す（無ければ''）。 }
function TForm1.ExtractMailHtmlBody(AMsg: TIdMessage): string;
var
  i: Integer;
  part: TObject;
  textPart: TIdText;
begin
  Result := '';
  for i := 0 to AMsg.MessageParts.Count - 1 do begin
    part := AMsg.MessageParts[i];
    if part is TIdText then begin
      textPart := TIdText(part);
      if Pos('html', LowerCase(textPart.ContentType)) > 0 then begin
        Result := textPart.Body.Text;
        Exit;
      end;
    end;
  end;
end;

{ メッセージ中のtext/plainパートを探す（無ければAMsg.Bodyそのもの）。 }
function TForm1.ExtractMailPlainBody(AMsg: TIdMessage): string;
var
  i: Integer;
  part: TObject;
  textPart: TIdText;
begin
  for i := 0 to AMsg.MessageParts.Count - 1 do begin
    part := AMsg.MessageParts[i];
    if part is TIdText then begin
      textPart := TIdText(part);
      if Pos('html', LowerCase(textPart.ContentType)) = 0 then begin
        Result := textPart.Body.Text;
        Exit;
      end;
    end;
  end;
  Result := AMsg.Body.Text;
end;

function TForm1.ExtractMailAttachmentList(AMsg: TIdMessage): string;
var
  i: Integer;
  part: TObject;
  att: TIdAttachment;
begin
  Result := '';
  for i := 0 to AMsg.MessageParts.Count - 1 do begin
    part := AMsg.MessageParts[i];
    if part is TIdAttachment then begin
      att := TIdAttachment(part);
      Result := Result + '- ' + att.FileName + '<br>';
    end;
  end;
end;

{ 添付削除/退避に使う移動先フォルダの下準備。Gmailかどうか・特殊フォルダ
  （ゴミ箱/迷惑メール）かどうかを判定し、必要ならフォルダを作成しておく。 }
procedure TForm1.PrepareDeleteFolder(const ADeleteFolder: string; out AIsGmail, AIsSpecialUseFolder: Boolean);
begin
  AIsGmail := False;
  AIsSpecialUseFolder := False;
  if ADeleteFolder = '' then Exit;

  AIsGmail := FIMAP4.IsGmailServer;
  if AIsGmail then
    AIsSpecialUseFolder := FIMAP4.IsSpecialUseMailBox(ADeleteFolder);

  if not AIsSpecialUseFolder then begin
    try
      FIMAP4.CreateMailBox(ADeleteFolder);
    except
      // 既に存在する場合など。無視して続行する。
    end;
  end;
end;

{ 指定UIDの元メールを、移動先フォルダへ退避（またはADeleteFolder=''なら削除）する。
  Gmailの通常ラベルの場合はラベル操作、それ以外はCOPY+DELETEを使う
  （DoProcessSelectedClickと同じ考え方）。 }
function TForm1.MoveOrDeleteOriginal(AUID: Int64; const ADeleteFolder: string;
  AIsGmail, AIsSpecialUseFolder: Boolean): Boolean;
var
  usedLabelMove: Boolean;
begin
  usedLabelMove := False;
  if ADeleteFolder <> '' then begin
    if AIsGmail and (not AIsSpecialUseFolder) then begin
      usedLabelMove := True;
      Result := FIMAP4.GmailAddLabel(AUID, ADeleteFolder);
    end
    else
      Result := FIMAP4.UIDCopyMsg(IntToStr(AUID), ADeleteFolder);
  end
  else
    Result := True; // 移動先未設定＝完全削除でよい

  if Result then begin
    if usedLabelMove then
      FIMAP4.GmailRemoveLabel(AUID, FolderName)
    else
      FIMAP4.UIDDeleteMsg(IntToStr(AUID));
  end;
end;

function TForm1.FindEntryByUID(AUID: Int64): TMailEntry;
var
  e: TMailEntry;
begin
  Result := nil;
  for e in FEntries do begin
    if e.UID = AUID then begin
      Result := e;
      Exit;
    end;
  end;
end;

{ メール本文取得の進捗（ダウンロード済みバイト数）をプログレスバーへ反映する。 }
procedure TForm1.DoFetchWorkBegin(ASender: TObject; AWorkMode: TWorkMode; AWorkCountMax: Int64);
begin
  UpdateProgress(0, AWorkCountMax, T('msg.mailFetching'));
end;

procedure TForm1.DoFetchWork(ASender: TObject; AWorkMode: TWorkMode; AWorkCount: Int64);
begin
  UpdateProgress(AWorkCount, pbProgress.Max, T('msg.mailFetching'));
end;

procedure TForm1.DoFetchWorkEnd(ASender: TObject; AWorkMode: TWorkMode);
begin
  ResetProgress;
end;

{ このメール1通だけ添付ファイルを削除する（一覧の「4. 選択した添付を削除」と同じ
  考え方を1通分だけ実行）。移動先フォルダ(DeleteFolderName)の設定に従う。
  IMAP通信自体はバックグラウンドスレッドで行い、メインスレッド（画面）を
  ブロックしないようにする（同期通信のままだと「フリーズしたように見える」
  どころか、サーバー応答が遅い時に実際に画面操作を受け付けなくなるため）。 }
procedure TForm1.RemoveAttachmentsForSingleMail(AUID: Int64; const ASubject: string);
var
  deleteFolder: string;
  th: TThread;
  entryObj: TMailEntry;
begin
  entryObj := FindEntryByUID(AUID);
  if Assigned(entryObj) and entryObj.IsProtected then begin
    ShowMessage(T('msg.protectedGuard'));
    Exit;
  end;

  deleteFolder := DeleteFolderName;
  if deleteFolder <> '' then begin
    if MessageDlg(Format(T('msg.updateConfirmMove'), [1, deleteFolder]), mtWarning, [mbYes, mbNo], 0) <> mrYes then
      Exit;
  end
  else begin
    if MessageDlg(Format(T('msg.updateConfirmNoMove'), [1]), mtWarning, [mbYes, mbNo], 0) <> mrYes then
      Exit;
  end;

  if not TryBeginNetworkOp then Exit;

  Screen.Cursor := crHourGlass;
  if Assigned(FViewerBtnDelAttach) then FViewerBtnDelAttach.Enabled := False;
  if Assigned(FViewerBtnDelMail) then FViewerBtnDelMail.Enabled := False;

  th := TThread.CreateAnonymousThread(
    procedure
    var
      msg: TIdMessage;
      removedCount: Integer;
      isGmail, isSpecialUseFolder, ok, succeeded: Boolean;
      errMsg: string;
    begin
      errMsg := '';
      succeeded := False;
      FIMAP4.OnWorkBegin := DoFetchWorkBegin;
      FIMAP4.OnWork := DoFetchWork;
      FIMAP4.OnWorkEnd := DoFetchWorkEnd;
      try
        try
          EnsureConnected;
          if not FIMAP4.SelectMailBox(FolderName) then
            raise Exception.Create(T('msg.folderSelectFailed'));

          PrepareDeleteFolder(deleteFolder, isGmail, isSpecialUseFolder);

          msg := TIdMessage.Create(nil);
          try
            if not FIMAP4.UIDRetrieve(IntToStr(AUID), msg) then
              raise Exception.Create(Format(T('msg.bodyFetchFailed'), [AUID, FIMAP4.GetLastReplyText]));

            if not StripAttachmentsFromMessage(msg, removedCount) then begin
              Log(Format(T('msg.noAttachmentSkip'), [AUID]));
              Exit;
            end;

            if not FIMAP4.AppendMsgWithDate(FolderName, msg, [mfSeen], msg.Date) then
              raise Exception.Create(Format(T('msg.appendFailed'), [AUID]));

            ok := MoveOrDeleteOriginal(AUID, deleteFolder, isGmail, isSpecialUseFolder);
            if not ok then begin
              Log(Format(T('msg.preserveFailed'), [AUID, deleteFolder]));
              Exit;
            end;

            FIMAP4.ExpungeMailBox;
            if deleteFolder <> '' then
              Log(Format(T('msg.removedMoved'), [AUID, removedCount, deleteFolder]))
            else
              Log(Format(T('msg.removedNoMove'), [AUID, removedCount]));

            succeeded := True;
          finally
            msg.Free;
          end;
        except
          on E: Exception do
            errMsg := E.Message;
        end;
      finally
        FIMAP4.OnWorkBegin := nil;
        FIMAP4.OnWork := nil;
        FIMAP4.OnWorkEnd := nil;
      end;

      RunOnMainThread(
        procedure
        var
          entryObj: TMailEntry;
          i: Integer;
        begin
          Screen.Cursor := crDefault;
          ResetProgress;
          if Assigned(FViewerBtnDelAttach) then FViewerBtnDelAttach.Enabled := True;
          if Assigned(FViewerBtnDelMail) then FViewerBtnDelMail.Enabled := True;
          EndNetworkOp;

          if errMsg <> '' then begin
            ShowMessage(errMsg);
            Exit;
          end;
          if not succeeded then Exit;

          entryObj := FindEntryByUID(AUID);
          if Assigned(entryObj) then begin
            FEntries.Extract(entryObj);
            FProcessedEntries.Add(entryObj);
          end;
          SaveScanCache(PeekLastScannedUID);

          for i := 0 to lvMails.Items.Count - 1 do begin
            if Assigned(lvMails.Items[i].Data) and (TMailEntry(lvMails.Items[i].Data).UID = AUID) then begin
              // 件名列(SubItems[4])に[済]を付ける
              lvMails.Items[i].SubItems[4] := T('note.processedPrefix') + ' ' + lvMails.Items[i].SubItems[4];
              entryObj.MarkedForAttachDelete := False;
              lvMails.Items[i].Caption := AttachDeleteMarkText(False);
              Break;
            end;
          end;

          if Assigned(FViewerDlg) then
            FViewerDlg.ModalResult := mrOk;
        end);
    end);
  th.FreeOnTerminate := True;
  th.Start;
end;

{ このメールそのものを移動先フォルダへ退避(またはADeleteFolder=''なら完全削除)する。
  添付を残したまま丸ごと退避/削除する点が「添付だけ削除」との違い。
  こちらもIMAP通信をバックグラウンドスレッドで行う。 }
procedure TForm1.DeleteMailEntirely(AUID: Int64; const ASubject: string);
var
  deleteFolder: string;
  confirmMsg: string;
  th: TThread;
  entryObj: TMailEntry;
begin
  entryObj := FindEntryByUID(AUID);
  if Assigned(entryObj) and entryObj.IsProtected then begin
    ShowMessage(T('msg.protectedGuard'));
    Exit;
  end;

  deleteFolder := DeleteFolderName;
  if deleteFolder <> '' then
    confirmMsg := Format(T('msg.deleteMailConfirmMove'), [ASubject, deleteFolder])
  else
    confirmMsg := Format(T('msg.deleteMailConfirmNoMove'), [ASubject]);
  if MessageDlg(confirmMsg, mtWarning, [mbYes, mbNo], 0) <> mrYes then Exit;

  if not TryBeginNetworkOp then Exit;

  Screen.Cursor := crHourGlass;
  if Assigned(FViewerBtnDelAttach) then FViewerBtnDelAttach.Enabled := False;
  if Assigned(FViewerBtnDelMail) then FViewerBtnDelMail.Enabled := False;

  th := TThread.CreateAnonymousThread(
    procedure
    var
      isGmail, isSpecialUseFolder, ok, succeeded: Boolean;
      errMsg: string;
    begin
      errMsg := '';
      succeeded := False;
      FIMAP4.OnWorkBegin := DoFetchWorkBegin;
      FIMAP4.OnWork := DoFetchWork;
      FIMAP4.OnWorkEnd := DoFetchWorkEnd;
      try
        try
          EnsureConnected;
          if not FIMAP4.SelectMailBox(FolderName) then
            raise Exception.Create(T('msg.folderSelectFailed'));

          PrepareDeleteFolder(deleteFolder, isGmail, isSpecialUseFolder);

          ok := MoveOrDeleteOriginal(AUID, deleteFolder, isGmail, isSpecialUseFolder);
          if not ok then begin
            Log(Format(T('msg.preserveFailed'), [AUID, deleteFolder]));
            Exit;
          end;

          FIMAP4.ExpungeMailBox;
          if deleteFolder <> '' then
            Log(Format(T('msg.mailMoved'), [AUID, deleteFolder]))
          else
            Log(Format(T('msg.mailDeleted'), [AUID]));

          succeeded := True;
        except
          on E: Exception do
            errMsg := E.Message;
        end;
      finally
        FIMAP4.OnWorkBegin := nil;
        FIMAP4.OnWork := nil;
        FIMAP4.OnWorkEnd := nil;
      end;

      RunOnMainThread(
        procedure
        var
          entryObj: TMailEntry;
          i: Integer;
        begin
          Screen.Cursor := crDefault;
          ResetProgress;
          if Assigned(FViewerBtnDelAttach) then FViewerBtnDelAttach.Enabled := True;
          if Assigned(FViewerBtnDelMail) then FViewerBtnDelMail.Enabled := True;
          EndNetworkOp;

          if errMsg <> '' then begin
            ShowMessage(errMsg);
            Exit;
          end;
          if not succeeded then Exit;

          entryObj := FindEntryByUID(AUID);
          if Assigned(entryObj) then begin
            FEntries.Extract(entryObj);
            FProcessedEntries.Add(entryObj);
          end;
          SaveScanCache(PeekLastScannedUID);

          for i := 0 to lvMails.Items.Count - 1 do begin
            if Assigned(lvMails.Items[i].Data) and (TMailEntry(lvMails.Items[i].Data).UID = AUID) then begin
              lvMails.Items.Delete(i);
              Break;
            end;
          end;

          if Assigned(FViewerDlg) then
            FViewerDlg.ModalResult := mrOk;
        end);
    end);
  th.FreeOnTerminate := True;
  th.Start;
end;

{ 実際の処理はバックグラウンドスレッドで非同期に行われる。成功時のダイアログの
  クローズは、その完了コールバック側（RemoveAttachmentsForSingleMail/
  DeleteMailEntirely内）で行うので、ここではボタンを押した合図を送るだけ。 }
procedure TForm1.DoViewerDeleteAttachClick(Sender: TObject);
begin
  RemoveAttachmentsForSingleMail(FViewerUID, FViewerSubject);
end;

procedure TForm1.DoViewerDeleteMailClick(Sender: TObject);
begin
  DeleteMailEntirely(FViewerUID, FViewerSubject);
end;

{ メーラーで開いたときのように、件名・差出人・日付のヘッダーとHTML本文を
  TWebBrowserで表示する（読み取り専用）。text/htmlが無いメールは、本文を
  <pre>で囲んでそのまま流し込む。右上に「添付ファイルを削除」「メールを削除」
  ボタンを置き、押すとmove-to folderの設定に従って処理してダイアログを閉じる。 }
procedure TForm1.ShowMailContentDialog(AUID: Int64; AMsg: TIdMessage; const ASubject: string);

  function HtmlEncode(const S: string): string;
  begin
    Result := StringReplace(S, '&', '&amp;', [rfReplaceAll]);
    Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
    Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
  end;

var
  dlg: TForm;
  web: TWebBrowser;
  toolPanel: TPanel;
  btnDelAttach, btnDelMail: TButton;
  htmlBody, bodyHtml, attachList, headerHtml, fullHtml, tempFile, url: string;
begin
  htmlBody := ExtractMailHtmlBody(AMsg);
  if htmlBody <> '' then
    bodyHtml := htmlBody
  else
    bodyHtml := '<pre style="font-family:inherit;white-space:pre-wrap;">' +
      HtmlEncode(ExtractMailPlainBody(AMsg)) + '</pre>';

  attachList := ExtractMailAttachmentList(AMsg);

  headerHtml :=
    '<div style="font-family:Segoe UI,Meiryo,sans-serif;font-size:13px;' +
    'border-bottom:1px solid #ccc;padding-bottom:8px;margin-bottom:8px;">' +
    '<b>' + HtmlEncode(T('col.from')) + ':</b> ' + HtmlEncode(AMsg.From.Text) + '<br>' +
    '<b>' + HtmlEncode(T('col.subject')) + ':</b> ' + HtmlEncode(ASubject) + '<br>' +
    '<b>' + HtmlEncode(T('col.date')) + ':</b> ' +
      HtmlEncode(FormatDateTime('yyyy/mm/dd hh:nn', AMsg.Date));
  if attachList <> '' then
    headerHtml := headerHtml + '<br><b>' + HtmlEncode(T('col.attachCount')) + ':</b><br>' + attachList;
  headerHtml := headerHtml + '</div>';

  fullHtml := '<html><head><meta charset="utf-8"></head><body>' +
    headerHtml + bodyHtml + '</body></html>';

  tempFile := IncludeTrailingPathDelimiter(GetEnvironmentVariable('TEMP')) +
    'imap_cleaner_view_' + IntToStr(GetTickCount) + '.html';
  TFile.WriteAllText(tempFile, fullHtml, TEncoding.UTF8);
  url := 'file:///' + StringReplace(tempFile, '\', '/', [rfReplaceAll]);

  dlg := TForm.Create(nil);
  try
    dlg.Caption := ASubject;
    dlg.Width := 800;
    dlg.Height := 600;
    dlg.Position := poScreenCenter;

    FViewerUID := AUID;
    FViewerSubject := ASubject;
    FViewerDlg := dlg;

    toolPanel := TPanel.Create(dlg);
    toolPanel.Parent := dlg;
    toolPanel.Align := alTop;
    toolPanel.Height := 36;
    toolPanel.BevelOuter := bvNone;

    btnDelMail := TButton.Create(dlg);
    btnDelMail.Parent := toolPanel;
    btnDelMail.Align := alRight;
    btnDelMail.Width := 140;
    btnDelMail.Caption := T('btn.deleteMailOne');
    btnDelMail.OnClick := DoViewerDeleteMailClick;

    btnDelAttach := TButton.Create(dlg);
    btnDelAttach.Parent := toolPanel;
    btnDelAttach.Align := alRight;
    btnDelAttach.Width := 160;
    btnDelAttach.Caption := T('btn.deleteAttachmentsOne');
    btnDelAttach.OnClick := DoViewerDeleteAttachClick;

    FViewerBtnDelAttach := btnDelAttach;
    FViewerBtnDelMail := btnDelMail;

    web := TWebBrowser.Create(dlg);
    // TWebBrowserはOLEの「Parent」プロパティ(IDispatch, 読み取り専用)がVCLの
    // TWinControl.Parentと同名で被っているため、TWinControlにキャストして設定する。
    TWinControl(web).Parent := dlg;
    web.Align := alClient;
    web.Navigate(url);

    // ボタンではなく本文側に初期フォーカスを当てる（誤操作でEnter一発で
    // 「メールを削除」等が実行されてしまうのを防ぐ）。
    btnDelMail.TabStop := False;
    btnDelAttach.TabStop := False;
    dlg.ActiveControl := TWinControl(web);

    dlg.ShowModal;
  finally
    FViewerDlg := nil;
    FViewerBtnDelAttach := nil;
    FViewerBtnDelMail := nil;
    dlg.Free;
    try
      DeleteFile(tempFile);
    except
    end;
  end;
end;

{ ダブルクリックでそのメールの本文を取得して表示する（読み取り専用。チェックは変更しない）。 }
{ ダブルクリックでそのメールの本文を取得して表示する（読み取り専用。チェックは変更しない）。
  本文取得(FIMAP4を使う区間)だけをロックで保護する。ダイアログ内の
  「添付ファイルを削除」「メールを削除」ボタンは、押された時点で
  RemoveAttachmentsForSingleMail/DeleteMailEntirelyが自分でロックを取り直すので、
  ダイアログを表示している間までロックを持ち続ける必要はない（むしろ持ち続けると
  同じスレッドからの再ロックで自分自身をブロックしてしまう）。 }
procedure TForm1.DoMailsDblClick(Sender: TObject);
var
  entry: TMailEntry;
  msg: TIdMessage;
  fetchOK: Boolean;
begin
  if not Assigned(lvMails.Selected) then Exit;
  entry := TMailEntry(lvMails.Selected.Data);
  if entry = nil then Exit;

  if not TryBeginNetworkOp then Exit;
  fetchOK := False;
  msg := TIdMessage.Create(nil);
  try
    try
      EnsureConnected;
    except
      on E: Exception do begin
        ShowMessage(E.Message);
        Exit;
      end;
    end;

    Screen.Cursor := crHourGlass;
    FIMAP4.OnWorkBegin := DoFetchWorkBegin;
    FIMAP4.OnWork := DoFetchWork;
    FIMAP4.OnWorkEnd := DoFetchWorkEnd;
    try
      // UIDRetrieve(非Peek)はRFC822形式でのFETCHとなり、Gmail相手だと応答の
      // パース失敗でOKなのにFalseが返ることがあったため、より安定するBODY.PEEK[]
      // 形式のUIDRetrievePeekを使う（\Seenも変化しないので閲覧用途にも合う）。
      if not FIMAP4.UIDRetrievePeek(IntToStr(entry.UID), msg) then
        Log(Format(T('msg.bodyFetchFailed'), [entry.UID, FIMAP4.GetLastReplyText]))
      else
        fetchOK := True;
    finally
      FIMAP4.OnWorkBegin := nil;
      FIMAP4.OnWork := nil;
      FIMAP4.OnWorkEnd := nil;
      Screen.Cursor := crDefault;
    end;
  finally
    EndNetworkOp;
  end;

  if fetchOK then
    ShowMailContentDialog(entry.UID, msg, entry.Subject);
  msg.Free;
end;

{ 右クリックでその行の件名をクリップボードへコピーする。 }
procedure TForm1.DoMailsMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  item: TListItem;
  entry: TMailEntry;
begin
  if Button = mbLeft then begin
    ToggleMarkColumnAtPoint(X, Y);
    Exit;
  end;
  if Button <> mbRight then Exit;
  item := lvMails.GetItemAt(X, Y);
  if item = nil then Exit;
  entry := TMailEntry(item.Data);
  if entry = nil then Exit;
  Clipboard.AsText := entry.Subject;
  Log(Format(T('msg.subjectCopied'), [entry.Subject]));
end;

function TForm1.SimpleObfuscate(const S: string): string;
var
  i: Integer;
  b: TIdBytes;
begin
  SetLength(b, Length(S) * SizeOf(Char));
  if Length(b) > 0 then
    Move(PChar(S)^, b[0], Length(b));
  for i := 0 to High(b) do
    b[i] := b[i] xor $5A;
  Result := TIdEncoderMIME.EncodeBytes(b);
end;

function TForm1.SimpleDeobfuscate(const S: string): string;
var
  i: Integer;
  b: TIdBytes;
begin
  Result := '';
  if S = '' then Exit;
  try
    b := TIdDecoderMIME.DecodeBytes(S);
    for i := 0 to High(b) do
      b[i] := b[i] xor $5A;
    if Length(b) > 0 then
      SetString(Result, PChar(@b[0]), Length(b) div SizeOf(Char));
  except
    Result := '';
  end;
end;

function TForm1.ProfileSectionName(const AName: string): string;
begin
  Result := 'Profile:' + AName;
end;

procedure TForm1.RefreshProfileList(const ASelectName: string);
var
  ini: TIniFile;
  namesStr: string;
  names: TArray<string>;
  s: string;
  lastProfile: string;
begin
  cboProfile.Items.Clear;
  if not FileExists(IniPath) then Exit;

  ini := TIniFile.Create(IniPath);
  try
    namesStr := ini.ReadString('Meta', 'Profiles', '');
    lastProfile := ini.ReadString('Meta', 'LastProfile', '');
  finally
    ini.Free;
  end;

  names := namesStr.Split([ProfileSep]);
  for s in names do
    if Trim(s) <> '' then
      cboProfile.Items.Add(Trim(s));

  if ASelectName <> '' then
    cboProfile.ItemIndex := cboProfile.Items.IndexOf(ASelectName)
  else if lastProfile <> '' then
    cboProfile.ItemIndex := cboProfile.Items.IndexOf(lastProfile);

  if (cboProfile.ItemIndex < 0) and (cboProfile.Items.Count > 0) then
    cboProfile.ItemIndex := 0;

  if cboProfile.ItemIndex >= 0 then
    cboProfile.Text := cboProfile.Items[cboProfile.ItemIndex];
end;

procedure TForm1.LoadProfileFields(const AName: string);
var
  ini: TIniFile;
  section: string;
begin
  if AName = '' then Exit;
  if not FileExists(IniPath) then Exit;

  section := ProfileSectionName(AName);
  ini := TIniFile.Create(IniPath);
  try
    if not ini.SectionExists(section) then Exit;
    edtHost.Text := ini.ReadString(section, 'Host', '');
    edtPort.Text := ini.ReadString(section, 'Port', '993');
    chkSSL.Checked := ini.ReadBool(section, 'SSL', True);
    edtUser.Text := ini.ReadString(section, 'UserName', '');
    edtPass.Text := SimpleDeobfuscate(ini.ReadString(section, 'Password', ''));
    cboFolder.Text := ini.ReadString(section, 'Folder', 'INBOX');
    edtMaxCount.Text := ini.ReadString(section, 'MaxCount', '200');
    cboDeleteFolder.Text := ini.ReadString(section, 'DeleteFolder', 'DeletedAttachments');
  finally
    ini.Free;
  end;
end;

procedure TForm1.SaveProfileFields(const AName: string);
var
  ini: TIniFile;
  section: string;
  namesStr: string;
  names: TArray<string>;
  s: string;
  found: Boolean;
begin
  if AName = '' then Exit;
  section := ProfileSectionName(AName);

  ini := TIniFile.Create(IniPath);
  try
    ini.WriteString(section, 'Host', edtHost.Text);
    ini.WriteString(section, 'Port', edtPort.Text);
    ini.WriteBool(section, 'SSL', chkSSL.Checked);
    ini.WriteString(section, 'UserName', edtUser.Text);
    ini.WriteString(section, 'Password', SimpleObfuscate(edtPass.Text));
    ini.WriteString(section, 'Folder', cboFolder.Text);
    ini.WriteString(section, 'MaxCount', edtMaxCount.Text);
    ini.WriteString(section, 'DeleteFolder', cboDeleteFolder.Text);

    // プロファイル名一覧に無ければ追加
    namesStr := ini.ReadString('Meta', 'Profiles', '');
    names := namesStr.Split([ProfileSep]);
    found := False;
    for s in names do
      if SameText(Trim(s), AName) then begin
        found := True;
        Break;
      end;
    if not found then begin
      if namesStr = '' then
        namesStr := AName
      else
        namesStr := namesStr + ProfileSep + AName;
      ini.WriteString('Meta', 'Profiles', namesStr);
    end;
  finally
    ini.Free;
  end;
end;

procedure TForm1.SaveLastProfile(const AName: string);
var
  ini: TIniFile;
begin
  if AName = '' then Exit;
  ini := TIniFile.Create(IniPath);
  try
    ini.WriteString('Meta', 'LastProfile', AName);
  finally
    ini.Free;
  end;
end;

// ドロップダウンからプロファイルを選び直したときに自動で内容を読み込む。
// （新規名を手入力中にも呼ばれるが、LoadProfileFieldsは未登録名なら何もしないので害はない）
procedure TForm1.DoProfileChange(Sender: TObject);
begin
  if Trim(cboProfile.Text) = '' then Exit;
  LoadProfileFields(Trim(cboProfile.Text));
end;

procedure TForm1.DoSaveProfileClick(Sender: TObject);
var
  name: string;
begin
  name := Trim(cboProfile.Text);
  if name = '' then begin
    ShowMessage(T('msg.profileNameRequired'));
    Exit;
  end;
  SaveProfileFields(name);
  SaveLastProfile(name);
  RefreshProfileList(name);
  ShowMessage(Format(T('msg.profileSaved'), [name]));
end;

procedure TForm1.DoDeleteProfileClick(Sender: TObject);
var
  name: string;
  ini: TIniFile;
  namesStr: string;
  names: TArray<string>;
  s, newNamesStr: string;
begin
  name := Trim(cboProfile.Text);
  if name = '' then Exit;
  if MessageDlg(Format(T('msg.profileDeleteConfirm'), [name]),
                mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    Exit;

  ini := TIniFile.Create(IniPath);
  try
    ini.EraseSection(ProfileSectionName(name));

    namesStr := ini.ReadString('Meta', 'Profiles', '');
    names := namesStr.Split([ProfileSep]);
    newNamesStr := '';
    for s in names do begin
      if (Trim(s) <> '') and not SameText(Trim(s), name) then begin
        if newNamesStr = '' then
          newNamesStr := Trim(s)
        else
          newNamesStr := newNamesStr + ProfileSep + Trim(s);
      end;
    end;
    ini.WriteString('Meta', 'Profiles', newNamesStr);

    if SameText(ini.ReadString('Meta', 'LastProfile', ''), name) then
      ini.WriteString('Meta', 'LastProfile', '');
  finally
    ini.Free;
  end;

  RefreshProfileList;
end;

function TForm1.FolderName: string;
begin
  Result := Trim(cboFolder.Text);
end;

function TForm1.MaxCountText: string;
begin
  Result := Trim(edtMaxCount.Text);
end;

function TForm1.DeleteFolderName: string;
begin
  Result := Trim(cboDeleteFolder.Text);
end;

{ Host/Port/User/Pass の内容で接続・ログインだけ行う（フォルダ選択はしない）。
  すでに接続済みならそのまま何もしない。失敗時は例外を投げる。 }
procedure TForm1.EnsureLoggedIn;
begin
  if FIMAP4.Connected then Exit;

  FIMAP4.Host := Trim(edtHost.Text);
  FIMAP4.Port := StrToIntDef(Trim(edtPort.Text), 993);
  FIMAP4.Username := edtUser.Text;
  FIMAP4.Password := edtPass.Text;

  if chkSSL.Checked then begin
    FIMAP4.IOHandler := FSSLHandler;
    FIMAP4.UseTLS := utUseImplicitTLS;
  end
  else begin
    FIMAP4.IOHandler := nil;
    FIMAP4.UseTLS := utNoTLSSupport;
  end;

  FIMAP4.Connect;

  // IndyのIOHandlerはデフォルトで1行16KBまでしか読めず、大きなメールボックスで
  // 検索結果や構造情報が長くなると EIdReadLnMaxLineLengthExceeded で落ちる。
  // 0を指定すると無制限になる。
  if Assigned(FIMAP4.IOHandler) then begin
    FIMAP4.IOHandler.MaxLineLength := 0;
    // タイムアウト未設定だと、サーバーが期待通りに応答しない場合に永久に
    // ハングしてしまう（UIが固まったまま戻らなくなる）。有限の値にして、
    // 何かあれば例外として復帰できるようにする。
    FIMAP4.IOHandler.ReadTimeout := 60000; // 60秒
  end;
end;

{ IMAPのLIST応答は本来 (\HasNoChildren) "/" "INBOX.Sent" のような形式で
  返ってくることがあるため、末尾のダブルクォートで囲まれた部分を取り出す。
  すでに名前だけの行であれば、そのままトリムして返す。 }
function TForm1.ExtractMailboxName(const ALine: string): string;
var
  p1, p2: Integer;
begin
  Result := Trim(ALine);
  if Result = '' then Exit;
  p2 := LastDelimiter('"', Result);
  if p2 > 1 then begin
    p1 := LastDelimiter('"', Copy(Result, 1, p2 - 1));
    if p1 > 0 then
      Result := Copy(Result, p1 + 1, p2 - p1 - 1);
  end;
end;

{ 指定フォルダ内を件名(部分一致)で検索し、見つかった各メールのUID・日付・
  添付有無をログへ出力する。削除処理後に「添付あり版がどこに行ったか」
  「添付なし版がどこにあるか」を実際に確認するための検証用機能。 }
procedure TForm1.VerifySubjectInFolder(const AFolder, ASubject: string);
var
  searchResult: TArray<Integer>;
begin
  if not FIMAP4.SelectMailBox(AFolder) then begin
    Log(Format(T('msg.verifyFolderSelectFailed'), [AFolder]));
    Exit;
  end;

  searchResult := FIMAP4.SearchBySubject(ASubject);

  if Length(searchResult) = 0 then begin
    Log(Format(T('msg.verifyNoMatch'), [AFolder, FIMAP4.GetLastReplyText]));
    Exit;
  end;

  // ヒットした全メールのUID/ENVELOPE/BODYSTRUCTUREを1回のFETCHでまとめて取得する
  // （1件ずつ通信すると、検索ヒット数が多いときに大幅に遅くなるため）。
  FIMAP4.RetrieveEnvelopesAndStructuresBySeqSet(searchResult,
    procedure(ASeq: Integer; AUID: string; AMsg: TIdMessage; AParts: TIdImapMessageParts)
    var
      p, attCount: Integer;
      attSize: Int64;
      attachDesc: string;
    begin
      attCount := 0;
      attSize := 0;
      for p := 0 to AParts.Count - 1 do
        if Trim(AParts[p].FileName) <> '' then begin
          Inc(attCount);
          attSize := attSize + AParts[p].Size;
        end;

      if attCount > 0 then
        attachDesc := Format(T('msg.attachYes'), [attCount, attSize / 1024])
      else
        attachDesc := T('msg.attachNo');

      Log(Format(T('msg.verifyResult'),
        [AFolder, AUID, DecodeHeader(AMsg.Subject),
         FormatDateTime('yyyy/mm/dd hh:nn', AMsg.Date), attachDesc]));
    end);
end;


procedure TForm1.DoClearCacheClick(Sender: TObject);
var
  fn: string;
begin
  fn := ScanCacheFileName;
  if not FileExists(fn) then begin
    Log(T('msg.noCacheYet'));
    Exit;
  end;
  if MessageDlg(Format(T('msg.clearCacheConfirm'), [Trim(cboProfile.Text)]),
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    Exit;

  DeleteFile(fn);
  ClearEntries;
  btnUpdate.Enabled := False;
  Log(T('msg.cacheCleared'));
end;

procedure TForm1.DoListFoldersClick(Sender: TObject);
var
  sl: TStringList;
  i: Integer;
  name: string;
  currentText, currentDeleteText: string;
begin
  if not TryBeginNetworkOp then Exit;
  try
    Screen.Cursor := crHourGlass;
    try
      try
        EnsureLoggedIn;

        currentText := cboFolder.Text;
        currentDeleteText := cboDeleteFolder.Text;
        sl := TStringList.Create;
        try
          FIMAP4.ListMailBoxes(sl);

          cboFolder.Items.Clear;
          cboDeleteFolder.Items.Clear;
          for i := 0 to sl.Count - 1 do begin
            name := ExtractMailboxName(sl[i]);
            if (name <> '') and (cboFolder.Items.IndexOf(name) < 0) then begin
              cboFolder.Items.Add(name);
              cboDeleteFolder.Items.Add(name);
            end;
          end;
        finally
          sl.Free;
        end;

        cboFolder.Text := currentText; // 選択操作でユーザー入力が消えないように
        cboDeleteFolder.Text := currentDeleteText;

        if cboFolder.Items.Count = 0 then
          Log(T('msg.foldersFailed'))
        else
          Log(Format(T('msg.foldersFetched'), [cboFolder.Items.Count]));
      except
        on E: Exception do
          Log(Format(T('msg.foldersFetchFailed'), [E.Message]));
      end;
    finally
      Screen.Cursor := crDefault;
    end;
  finally
    EndNetworkOp;
  end;
end;

procedure TForm1.DoConnectClick(Sender: TObject);
var
  doAutoList: Boolean;
begin
  if not TryBeginNetworkOp then Exit;
  doAutoList := False;
  try
    Screen.Cursor := crHourGlass;
    try
      try
        if FIMAP4.Connected then
          FIMAP4.Disconnect;

        EnsureLoggedIn;

        if not FIMAP4.SelectMailBox(FolderName) then begin
          Log(T('msg.folderSelectFailed'));
          Exit;
        end;

        // 接続に成功した内容を、コンボボックスに入っている名前でプロファイル保存
        if Trim(cboProfile.Text) <> '' then begin
          SaveProfileFields(Trim(cboProfile.Text));
          SaveLastProfile(Trim(cboProfile.Text));
        end;

        lblStatus.Caption := Format(T('msg.connected'), [FIMAP4.Host, FIMAP4.MailBox.TotalMsgs]);
        Log(Format(T('msg.connectedLog'), [FIMAP4.Host, FolderName]));
        btnList.Enabled := True;

        // 接続に成功したら、「接続後に自動で一覧取得する」がONのときだけ続けて実行
        // （DoListMails自体もロックを取るため、ここでは呼ばずフラグだけ立てて、
        //   ロックを解放してから呼び出す）
        doAutoList := chkAutoList.Checked;
      except
        on E: Exception do
          Log(Format(T('msg.connectFailed'), [E.Message]));
      end;
    finally
      Screen.Cursor := crDefault;
    end;
  finally
    EndNetworkOp;
  end;

  if doAutoList then
    DoListMails(Sender);
end;

const
  ListChunkSize = 5000; // 1回のFETCHコマンドでまとめて問い合わせるUID幅

function TForm1.ScanCacheFileName: string;
const
  InvalidChars: array[0..8] of Char = ('\', '/', ':', '*', '?', '"', '<', '>', '|');
var
  name: string;
  i: Integer;
begin
  name := Trim(cboProfile.Text);
  if name = '' then name := 'default';
  for i := 0 to High(InvalidChars) do
    name := StringReplace(name, InvalidChars[i], '_', [rfReplaceAll]);
  // プロファイルごとにフォルダを分けて保存する
  Result := ExtractFilePath(IniPath) + name + '\scan.tsv';
end;

{ 自動検証で応答パースに失敗したUIDを記録するファイル。次回以降このUIDは
  自動検証をスキップする（削除・退避処理自体はスキップしない）。 }
function TForm1.VerifySkipFileName: string;
begin
  Result := ExtractFilePath(ScanCacheFileName) + 'verify_skip.tsv';
end;

function TForm1.IsUIDInVerifySkipList(AUID: Int64): Boolean;
var
  sl: TStringList;
  fn: string;
begin
  Result := False;
  fn := VerifySkipFileName;
  if not FileExists(fn) then Exit;
  sl := TStringList.Create;
  try
    sl.LoadFromFile(fn, TEncoding.UTF8);
    Result := sl.IndexOf(IntToStr(AUID)) >= 0;
  finally
    sl.Free;
  end;
end;

procedure TForm1.AddUIDToVerifySkipList(AUID: Int64);
var
  f: TextFile;
  fn: string;
begin
  if IsUIDInVerifySkipList(AUID) then Exit;
  fn := VerifySkipFileName;
  try
    ForceDirectories(ExtractFilePath(fn));
    AssignFile(f, fn);
    {$I-}
    Append(f);
    if IOResult <> 0 then
      Rewrite(f);
    {$I+}
    try
      WriteLn(f, IntToStr(AUID));
    finally
      CloseFile(f);
    end;
  except
    // 記録に失敗しても致命的ではない（次回また同じUIDで時間がかかるだけ）
  end;
end;

{ ユーザーが「消したくない」と保護指定したUIDの一覧ファイル。
  一覧取得のたびに読み込んで、一覧の「保護」列と一括削除対象からの除外に使う。 }
function TForm1.ProtectedFileName: string;
begin
  Result := ExtractFilePath(ScanCacheFileName) + 'protected.tsv';
end;

function TForm1.LoadProtectedUIDs: TDictionary<Int64, Boolean>;
var
  sl: TStringList;
  i: Integer;
  uid: Int64;
begin
  Result := TDictionary<Int64, Boolean>.Create;
  if not FileExists(ProtectedFileName) then Exit;
  sl := TStringList.Create;
  try
    sl.LoadFromFile(ProtectedFileName, TEncoding.UTF8);
    for i := 0 to sl.Count - 1 do begin
      uid := StrToInt64Def(Trim(sl[i]), 0);
      if uid > 0 then
        Result.AddOrSetValue(uid, True);
    end;
  finally
    sl.Free;
  end;
end;

procedure TForm1.SetUIDProtected(AUID: Int64; AProtect: Boolean);
var
  ids: TDictionary<Int64, Boolean>;
  sl: TStringList;
  uid: Int64;
  fn: string;
begin
  ids := LoadProtectedUIDs;
  try
    if AProtect then
      ids.AddOrSetValue(AUID, True)
    else
      ids.Remove(AUID);

    fn := ProtectedFileName;
    sl := TStringList.Create;
    try
      for uid in ids.Keys do
        sl.Add(IntToStr(uid));
      try
        ForceDirectories(ExtractFilePath(fn));
        sl.SaveToFile(fn, TEncoding.UTF8);
      except
        // 保存に失敗しても致命的ではない
      end;
    finally
      sl.Free;
    end;
  finally
    ids.Free;
  end;
end;

function TForm1.ProtectMarkText(AProtected: Boolean): string;
begin
  if AProtected then
    Result := '✓' {Do not Localize}
  else
    Result := '';
end;

function TForm1.DeleteMailMarkText(AMarked: Boolean): string;
begin
  if AMarked then
    Result := '✓' {Do not Localize}
  else
    Result := '';
end;

function TForm1.AttachDeleteMarkText(AMarked: Boolean): string;
begin
  if AMarked then
    Result := '✓' {Do not Localize}
  else
    Result := '';
end;

{ 一覧の「添付削除」「メール削除」「保護」列（先頭3列）がクリックされた行のON/OFFを
  切り替える。3列ともクリックした場所で反応する統一的な挙動にするため、標準の
  TListView.Checkboxesは使わず、他の2列と同じテキストマーク方式にしている。
  列の境界はColumns[i].Widthの累積で概算する（横スクロールしていない前提）。 }
procedure TForm1.ToggleMarkColumnAtPoint(X, Y: Integer);
var
  item: TListItem;
  entry: TMailEntry;
  colStart: Integer;
  i, colIndex: Integer;
  attachDeleteColIndex, protectColIndex, deleteMailColIndex: Integer;
begin
  if lvMails.Columns.Count < 8 then Exit;
  item := lvMails.GetItemAt(X, Y);
  if item = nil then Exit;
  entry := TMailEntry(item.Data);
  if entry = nil then Exit;

  // 列順: 添付削除(0), メール削除(1), 保護(2), 日付, 差出人, 件名, 添付数, 添付合計サイズ
  attachDeleteColIndex := 0;
  deleteMailColIndex := 1;
  protectColIndex := 2;

  colIndex := -1;
  colStart := 0;
  for i := 0 to lvMails.Columns.Count - 1 do begin
    if (X >= colStart) and (X <= colStart + lvMails.Columns[i].Width) then begin
      colIndex := i;
      Break;
    end;
    colStart := colStart + lvMails.Columns[i].Width;
  end;

  if colIndex = attachDeleteColIndex then begin
    if entry.IsProtected then Exit; // 保護中は「添付削除」を付けさせない
    entry.MarkedForAttachDelete := not entry.MarkedForAttachDelete;
    item.Caption := AttachDeleteMarkText(entry.MarkedForAttachDelete);
  end
  else if colIndex = protectColIndex then begin
    entry.IsProtected := not entry.IsProtected;
    SetUIDProtected(entry.UID, entry.IsProtected);
    item.SubItems[protectColIndex - 1] := ProtectMarkText(entry.IsProtected);
    if entry.IsProtected then begin
      // 保護したら、念のため他のチェックも外す
      entry.MarkedForAttachDelete := False;
      item.Caption := AttachDeleteMarkText(False);
      entry.MarkedForDelete := False;
      item.SubItems[deleteMailColIndex - 1] := DeleteMailMarkText(False);
    end;
  end
  else if colIndex = deleteMailColIndex then begin
    if entry.IsProtected then Exit; // 保護中は「メール削除」を付けさせない
    entry.MarkedForDelete := not entry.MarkedForDelete;
    item.SubItems[deleteMailColIndex - 1] := DeleteMailMarkText(entry.MarkedForDelete);
  end;
end;

{ メールそのものが無くなった（一括メール削除で成功した）行を一覧から取り除く。
  添付削除と違い置き換え版が残らないため、[済]表示ではなく行ごと削除する。 }
procedure TForm1.RemoveEntryFromList(AEntry: TMailEntry);
begin
  RunOnMainThreadSync(
    procedure
    var
      j: Integer;
    begin
      FEntries.Extract(AEntry);
      for j := 0 to lvMails.Items.Count - 1 do begin
        if lvMails.Items[j].Data = AEntry then begin
          lvMails.Items.Delete(j);
          Break;
        end;
      end;
      AEntry.Free;
    end);
end;

{ 前回までに見つかった添付ありメール一覧と、どこまで検索済みか(LastUID)を
  ファイルから読み込みFEntriesへ追加する。ファイルが無ければ何もしない。 }
procedure TForm1.LoadScanCache(out ALastUID: Int64);
var
  fn: string;
  sl: TStringList;
  i: Integer;
  parts: TArray<string>;
  e: TMailEntry;
begin
  ALastUID := 0;
  fn := ScanCacheFileName;
  if not FileExists(fn) then Exit;

  sl := TStringList.Create;
  try
    sl.LoadFromFile(fn, TEncoding.UTF8);
    if sl.Count = 0 then Exit;
    if Copy(sl[0], 1, 8) = 'LASTUID=' then
      ALastUID := StrToInt64Def(Copy(sl[0], 9, MaxInt), 0);
    for i := 1 to sl.Count - 1 do begin
      if Trim(sl[i]) = '' then Continue;
      parts := sl[i].Split([#9]);
      if Length(parts) < 6 then Continue;
      e := TMailEntry.Create;
      e.UID := StrToInt64Def(parts[0], 0);
      e.DateStr := parts[1];
      e.From := parts[2];
      e.Subject := parts[3];
      e.AttachCount := StrToIntDef(parts[4], 0);
      e.AttachTotalSize := StrToInt64Def(parts[5], 0);
      e.Msg := nil;
      FEntries.Add(e);
    end;
  finally
    sl.Free;
  end;
end;

{ FEntries（累計で見つかっている添付ありメール全件）とLastUIDをファイルへ保存する。
  タイムアウト等で検索が中断しても、次回はここから続きを検索できる。 }
procedure TForm1.SaveScanCache(const ALastUID: Int64);
var
  sl: TStringList;
  e: TMailEntry;
  safeFrom, safeSubject: string;
begin
  sl := TStringList.Create;
  try
    sl.Add('LASTUID=' + IntToStr(ALastUID));
    for e in FEntries do begin
      safeFrom := StringReplace(e.From, #9, ' ', [rfReplaceAll]);
      safeFrom := StringReplace(safeFrom, #13#10, ' ', [rfReplaceAll]);
      safeFrom := StringReplace(safeFrom, #10, ' ', [rfReplaceAll]);
      safeSubject := StringReplace(e.Subject, #9, ' ', [rfReplaceAll]);
      safeSubject := StringReplace(safeSubject, #13#10, ' ', [rfReplaceAll]);
      safeSubject := StringReplace(safeSubject, #10, ' ', [rfReplaceAll]);
      sl.Add(Format('%d'#9'%s'#9'%s'#9'%s'#9'%d'#9'%d',
        [e.UID, e.DateStr, safeFrom, safeSubject, e.AttachCount, e.AttachTotalSize]));
    end;
    ForceDirectories(ExtractFilePath(ScanCacheFileName));
    sl.SaveToFile(ScanCacheFileName, TEncoding.UTF8);
  finally
    sl.Free;
  end;
end;

{ ファイル1行目のLASTUIDだけを読む（全件パースするLoadScanCacheより軽量）。 }
function TForm1.PeekLastScannedUID: Int64;
var
  fn: string;
  sl: TStringList;
begin
  Result := 0;
  fn := ScanCacheFileName;
  if not FileExists(fn) then Exit;
  sl := TStringList.Create;
  try
    sl.LoadFromFile(fn, TEncoding.UTF8);
    if (sl.Count > 0) and (Copy(sl[0], 1, 8) = 'LASTUID=') then
      Result := StrToInt64Def(Copy(sl[0], 9, MaxInt), 0);
  finally
    sl.Free;
  end;
end;

procedure TForm1.DoListMails(Sender: TObject);
var
  total: Integer;
  highestUID, lastUID, chunkFromUID, chunkToUID: Int64;
  highestUIDStr: string;
  targetCount, foundCount: Integer;
  entry: TMailEntry;
  item: TListItem;
  displayList: TList<TMailEntry>;
  protIDs: TDictionary<Int64, Boolean>;
begin
  if not TryBeginNetworkOp then Exit;
  try
  try
    EnsureConnected;
    ClearEntries;

    // 念のためフォルダを選択し直して最新の総数を取得
    if not FIMAP4.SelectMailBox(FolderName) then
      raise Exception.Create(Format(T('msg.folderSelectFailedName'), [FolderName]));

    total := FIMAP4.MailBox.TotalMsgs;
    targetCount := StrToIntDef(MaxCountText, 50);
    if targetCount <= 0 then targetCount := MaxInt; // 0=添付ありを全件見つけるまで検索

    if total = 0 then begin
      Log(T('msg.noMails'));
      Exit;
    end;

    // 前回までの検索結果（添付ありメール一覧とどこまで調べたか）をキャッシュから復元。
    // これにより、タイムアウト等で中断しても次回は続きから検索でき、
    // 巨大なメールボックスを毎回最初から再スキャンせずに済む。
    LoadScanCache(lastUID);
    foundCount := FEntries.Count;
    if lastUID > 0 then
      Log(Format(T('msg.resumeSearch'), [lastUID, foundCount]))
    else
      Log(Format(T('msg.searchFromOldest'), [total]));

    if foundCount < targetCount then begin
      if not FIMAP4.GetUID(total, highestUIDStr) then
        raise Exception.Create(T('msg.latestUidFailed'));
      highestUID := StrToInt64Def(highestUIDStr, 0);
      if highestUID <= 0 then highestUID := 1;

      chunkFromUID := lastUID + 1;
      Screen.Cursor := crHourGlass;
      try
        // ENVELOPE（件名・差出人・日付）とBODYSTRUCTURE（添付のファイル名・サイズ等）を
        // UID範囲まとめて1回のFETCHコマンドで取得する。添付の中身は一切ダウンロードしない。
        // 実際に本文まるごと取得するのは、更新でチェックしたメールだけ（DoProcessSelectedClick側）。
        while (chunkFromUID <= highestUID) and (foundCount < targetCount) do begin
          chunkToUID := chunkFromUID + ListChunkSize - 1;
          if chunkToUID > highestUID then chunkToUID := highestUID;

          UpdateProgress(Round((chunkFromUID / highestUID) * 100), 100,
            Format(T('msg.searchProgress'), [foundCount, chunkFromUID, chunkToUID]));

          try
            FIMAP4.RetrieveEnvelopesAndStructures(chunkFromUID, chunkToUID,
              procedure(AUID: Int64; AMsg: TIdMessage; AParts: TIdImapMessageParts)
              var
                p: Integer;
                attCount: Integer;
                attSize: Int64;
                e: TMailEntry;
              begin
                attCount := 0;
                attSize := 0;
                for p := 0 to AParts.Count - 1 do begin
                  // ファイル名を持つパートを「添付」とみなす（本文/インライン画像以外）
                  if Trim(AParts[p].FileName) <> '' then begin
                    Inc(attCount);
                    attSize := attSize + AParts[p].Size;
                  end;
                end;

                // 1回のFETCH範囲(チャンク)の中に目標件数を超える添付付きメールが
                // 含まれていることがあるため、目標に達した分は追加しない。
                if (attCount > 0) and (foundCount < targetCount) then begin
                  e := TMailEntry.Create;
                  e.UID := AUID;
                  e.Subject := DecodeHeader(AMsg.Subject);
                  e.From := DecodeHeader(AMsg.From.Text);
                  e.DateStr := FormatDateTime('yyyy/mm/dd hh:nn', AMsg.Date);
                  e.AttachCount := attCount;
                  e.AttachTotalSize := attSize;
                  e.Msg := nil; // 本文はまだ未取得。更新処理の対象になった時点で取得する。
                  FEntries.Add(e);
                  Inc(foundCount);
                end;
              end);
            lastUID := chunkToUID;
          except
            on E: Exception do begin
              // 1チャンクの通信エラー（タイムアウト等）で全体を失敗させず、
              // ここまでの結果は残したまま次のチャンクへ進む。
              Log(Format(T('msg.chunkFetchError'),
                [chunkFromUID, chunkToUID, E.Message]));
              ClearIOBuffer;
              lastUID := chunkToUID; // 無限ループ防止のため、失敗しても位置は進める
              if not FIMAP4.Connected then begin
                SaveScanCache(lastUID);
                Log(T('msg.disconnectedDuringSearch'));
                Break;
              end;
            end;
          end;

          // 途中経過をこまめに保存（タイムアウト等で中断しても続きから再開できるように）
          SaveScanCache(lastUID);

          chunkFromUID := chunkToUID + 1;
        end;
      finally
        Screen.Cursor := crDefault;
        ResetProgress;
      end;
    end;

    // キャッシュ全体（古い順）のうち先頭targetCount件を、新しい順に並べ替えて一覧表示
    displayList := TList<TMailEntry>.Create;
    try
      for entry in FEntries do begin
        displayList.Add(entry);
        if displayList.Count >= targetCount then Break;
      end;
      displayList.Sort(TComparer<TMailEntry>.Construct(
        function(const L, R: TMailEntry): Integer
        begin
          if L.UID > R.UID then Result := -1
          else if L.UID < R.UID then Result := 1
          else Result := 0;
        end));

      protIDs := LoadProtectedUIDs;
      try
        lvMails.Items.BeginUpdate;
        try
          for entry in displayList do begin
            entry.IsProtected := protIDs.ContainsKey(entry.UID);

            item := lvMails.Items.Add;
            // 列順: 添付削除, メール削除, 保護, 日付, 差出人, 件名, 添付数, 添付合計サイズ
            // 誤操作防止のため、初期状態はどれも未チェック（ユーザーが選んでからチェックする）
            item.Caption := AttachDeleteMarkText(entry.MarkedForAttachDelete);
            item.SubItems.Add(DeleteMailMarkText(entry.MarkedForDelete));
            item.SubItems.Add(ProtectMarkText(entry.IsProtected));
            item.SubItems.Add(entry.DateStr);
            item.SubItems.Add(entry.From);
            item.SubItems.Add(entry.Subject);
            item.SubItems.Add(IntToStr(entry.AttachCount));
            item.SubItems.Add(Format('%.1f KB', [entry.AttachTotalSize / 1024]));
            item.Data := entry;
          end;
        finally
          lvMails.Items.EndUpdate;
        end;
      finally
        protIDs.Free;
      end;

      Log(Format(T('msg.searchComplete'),
        [displayList.Count, FEntries.Count]));
    finally
      displayList.Free;
    end;

    // 一覧取得のたびに、添付合計サイズが大きい順に並べ替える
    FSortColumn := 7;
    FSortAscending := False;
    lvMails.CustomSort(nil, FSortColumn);

    btnUpdate.Enabled := lvMails.Items.Count > 0;
  except
    on E: Exception do begin
      Log(Format(T('msg.listError'), [E.Message]));
      ShowMessage(Format(T('msg.listFailed'), [E.Message]));
    end;
  end;
  finally
    EndNetworkOp;
  end;
end;

{ メッセージから添付パートだけを取り除く。
  本文(text/plain, text/html)や、HTML内で参照されるインライン画像以外の
  「ファイル名を持つ添付」を削除対象とする。 }
{ 削除した添付ファイル名(+サイズ)を本文の先頭に注記として書き加える。
  添付パート自体にファイル名を持たせる方式(Thunderbird風のDeleted:スタブ)は
  Gmail上でファイル名が全く表示されないことが確認できたため、本文注記方式に統一する。 }
procedure InsertRemovedNoteIntoBody(AMsg: TIdMessage; const ANoteLines, ANoteHtml: string);
var
  i: Integer;
  part: TObject;
  textPart: TIdText;
  isHtml: Boolean;
  bodyStr: string;
  insertPos: Integer;
  foundTextPart: Boolean;
begin
  foundTextPart := False;
  for i := 0 to AMsg.MessageParts.Count - 1 do begin
    part := AMsg.MessageParts[i];
    if part is TIdText then begin
      textPart := TIdText(part);
      isHtml := Pos('html', LowerCase(textPart.ContentType)) > 0;
      if isHtml then begin
        bodyStr := textPart.Body.Text;
        insertPos := Pos('<body', LowerCase(bodyStr));
        if insertPos > 0 then begin
          insertPos := PosEx('>', bodyStr, insertPos);
          if insertPos > 0 then
            Insert(ANoteHtml, bodyStr, insertPos + 1)
          else
            bodyStr := ANoteHtml + bodyStr;
        end else
          bodyStr := ANoteHtml + bodyStr;
        textPart.Body.Text := bodyStr;
      end else begin
        textPart.Body.Text := ANoteLines + textPart.Body.Text;
      end;
      foundTextPart := True;
    end;
  end;

  if not foundTextPart then
    AMsg.Body.Text := ANoteLines + AMsg.Body.Text;
end;

function TForm1.StripAttachmentsFromMessage(AMsg: TIdMessage; out RemovedCount: Integer): Boolean;
var
  i: Integer;
  part: TObject; // Indyのバージョンによって基底クラス名(TIdMessagePart等)が異なるためTObjectで受ける
  att: TIdAttachment;
  removed: Boolean;
  removedNames: TStringList;
  name: string;
  sizeStr: string;
  sz: Int64;
  noteLines, noteHtml: string;
begin
  RemovedCount := 0;
  removed := False;
  removedNames := TStringList.Create;
  try
    // 後ろから走査して削除時のインデックスずれを回避
    for i := AMsg.MessageParts.Count - 1 downto 0 do begin
      part := AMsg.MessageParts[i];
      if part is TIdAttachment then begin
        att := TIdAttachment(part);
        sz := 0;
        if att is TIdAttachmentMemory then
          sz := TIdAttachmentMemory(att).DataStream.Size;
        if sz > 0 then
          sizeStr := Format(' (%.1f KB)', [sz / 1024])
        else
          sizeStr := '';
        if att.FileName <> '' then
          name := att.FileName
        else
          name := T('note.unnamedAttachment') + IntToStr(removedNames.Count + 1);
        removedNames.Add(name + sizeStr);
        AMsg.MessageParts.Delete(i);
        Inc(RemovedCount);
        removed := True;
      end;
    end;

    if removed then begin
      noteLines := '';
      noteHtml := '<div style="border:1px solid #ccc;background:#f5f5f5;padding:8px;' +
        'margin-bottom:8px;font-size:13px;">';
      for name in removedNames do begin
        noteLines := noteLines + 'Deleted: ' + name + sLineBreak;
        noteHtml := noteHtml + 'Deleted: ' + name + '<br>';
      end;
      noteLines := noteLines + sLineBreak;
      noteHtml := noteHtml + '</div>';

      InsertRemovedNoteIntoBody(AMsg, noteLines, noteHtml);
    end;
  finally
    removedNames.Free;
  end;
  Result := removed;
end;

{ 「添付削除」列にチェックが付いているメールの添付ファイルを取り除く処理の本体。
  AImapは呼び出し元が接続・SelectMailBox済みのものを渡す（バックグラウンドスレッド
  から呼ばれる想定。Log/UpdateProgress等は内部で自動的にメインスレッドへrouteする）。 }
procedure TForm1.ProcessAttachDeleteTargets(AImap: TIdIMAP4Batch; ATargets: TList<TMailEntry>;
  const ADeleteFolder: string; AIsGmail, AIsSpecialUseFolder, AAutoVerify: Boolean;
  out ATotalMails, ATotalRemoved: Integer);
var
  entry: TMailEntry;
  entryUID: Int64;
  entrySubject: string;
  removedCount, doneCount: Integer;
  copiedOriginal, usedLabelMove: Boolean;
begin
  ATotalMails := 0;
  ATotalRemoved := 0;
  doneCount := 0;
  for entry in ATargets do begin
    entryUID := entry.UID; // entryはこの後の処理成功時にFEntriesから削除(=解放)されるため先に控えておく
    entrySubject := entry.Subject;
    Inc(doneCount);
    UpdateProgress(doneCount, ATargets.Count,
      Format(T('msg.updateProgress'), [doneCount, ATargets.Count, entryUID]));
    try
      copiedOriginal := True;
      usedLabelMove := False;

      // 【重要】退避（コピー/ラベル操作）より先に、必ず本文をまるごと
      // ダウンロードしておく。Gmailでは移動先が「ゴミ箱」等の特殊フォルダの
      // 場合、コピー/ラベル追加した時点でGmail側がその場で元メールを
      // INBOXから外してしまうことがある（ゴミ箱は他のラベルと共存しない
      // 扱いのため）。退避を先にやると、そのせいでUIDが無効になり、
      // 直後の本文取得が失敗してしまう。本文取得を必ず先に行うことで、
      // 退避先がどんな特殊フォルダであっても影響を受けないようにする。
      entry.Msg := TIdMessage.Create(nil);
      // UIDRetrieve(非Peek)はRFC822形式でのFETCHとなり、Gmail相手だと応答の
      // パース失敗でOKなのにFalseが返ることがあったため、より安定するBODY.PEEK[]
      // 形式のUIDRetrievePeekを使う（どうせ直後に元メールは退避/削除するので
      // \Seenが変化しないことは問題にならない）。
      if not AImap.UIDRetrievePeek(IntToStr(entryUID), entry.Msg) then begin
        // 取得失敗の原因が「パース不具合」か「そもそも既に存在しない
        // （前回の実行で処理済み等でキャッシュが古いまま）」かを軽量チェックで
        // 見分ける。既に存在しないなら、キャッシュ/一覧からも取り除いて次回
        // またここで無駄に足止めされないようにする。
        if AImap.UIDExists(IntToStr(entryUID)) then
          Log(Format(T('msg.bodyFetchFailed'),
            [entryUID, AImap.GetLastReplyText]))
        else begin
          Log(Format(T('msg.bodyGoneRemovedCache'), [entryUID]));
          MarkEntryProcessed(entry);
        end;
        Continue;
      end;

      if not StripAttachmentsFromMessage(entry.Msg, removedCount) then begin
        Log(Format(T('msg.noAttachmentSkip'), [entryUID]));
        Continue;
      end;

      // 添付を抜いたメッセージを同じフォルダへ追加登録
      // （本文はすでに手元にあるので、これ以降は元メールのUIDが
      //   無効になっても問題ない）
      // \Seenを付け、かつ元メールと同じ日時(INTERNALDATE)で追加する。
      // どちらもしないと「今日届いた新着未読メール」のように見えてしまい、
      // 処理する度に新規メールが届いたかのような通知が出てしまうため。
      if not AImap.AppendMsgWithDate(FolderName, entry.Msg, [mfSeen], entry.Msg.Date) then begin
        Log(Format(T('msg.appendFailed'), [entryUID]));
        Continue;
      end;

      // 添付なし版の再登録に成功したので、ここで初めて元メール（添付あり）を退避する。
      if ADeleteFolder <> '' then begin
        if AIsGmail and (not AIsSpecialUseFolder) then begin
          usedLabelMove := True;
          copiedOriginal := AImap.GmailAddLabel(entryUID, ADeleteFolder);
        end
        else
          copiedOriginal := AImap.UIDCopyMsg(IntToStr(entryUID), ADeleteFolder);

        if not copiedOriginal then
          Log(Format(T('msg.preserveFailed'),
            [entryUID, ADeleteFolder]));
      end
      else
        copiedOriginal := True; // 移動先未設定＝完全削除でよい

      // 退避（またはコピー不要）に成功した場合のみ、元メールを対象フォルダから外す。
      // Gmailでラベル退避した場合は、ここで元フォルダのラベルを外すだけで完結
      // （\Deleted+EXPUNGEを一切使わないため、ゴミ箱へ落ちる事故が起きない）。
      // それ以外は従来どおり削除フラグを立て、後でまとめてExpungeする。
      if copiedOriginal then begin
        if usedLabelMove then
          AImap.GmailRemoveLabel(entryUID, FolderName)
        else
          AImap.UIDDeleteMsg(IntToStr(entryUID));
      end;

      Inc(ATotalMails);
      ATotalRemoved := ATotalRemoved + removedCount;
      if not copiedOriginal then
        Log(Format(T('msg.preserveFailedKept'),
          [entryUID, ADeleteFolder]))
      else if ADeleteFolder <> '' then
        Log(Format(T('msg.removedMoved'),
          [entryUID, removedCount, ADeleteFolder]))
      else
        Log(Format(T('msg.removedNoMove'), [entryUID, removedCount]));

      // 処理済み（元メールの退避まで完了した分）は、次回のキャッシュには含めない
      // （再スキャン時に重複して出てこないように）。ただし今表示している一覧
      // からは消さない＝FEntriesからは抜くがオブジェクトは解放せず保持し続け、
      // ユーザーがその場で結果を見比べられるようにする。
      // （FEntries/lvMailsの更新はメインスレッドへ同期して行う）
      if copiedOriginal then
        MarkEntryProcessed(entry);

      // 自動検証: 実際に元フォルダ・移動先フォルダへ正しく反映されたかをその場で確認する。
      // 件名が長い/特殊文字を含むメールでは、サーバーが応答をIMAPの
      // リテラル形式で送ってきた際に自前パーサーが行数を誤判定し、
      // 応答が来ているのに待ち続けてしまうことがある（60秒×数回で
      // 数分単位の停止になる）。検証中だけタイムアウトを短くして被害を
      // 抑えつつ、一度失敗したUIDはファイルに記録して次回以降スキップする。
      if not AAutoVerify then begin
        // チェックボックスでOFFにされている場合は検証自体を行わない
      end
      else if not IsUIDInVerifySkipList(entryUID) then begin
        if Assigned(AImap.IOHandler) then
          AImap.IOHandler.ReadTimeout := 30000;
        try
          try
            Log(T('msg.verifyHeader'));
            VerifySubjectInFolder(FolderName, entrySubject);
            if (ADeleteFolder <> '') and not SameText(ADeleteFolder, FolderName) then
              VerifySubjectInFolder(ADeleteFolder, entrySubject);
          except
            on E: Exception do begin
              Log(Format(T('msg.verifySkipAdded'), [entryUID, E.Message]));
              AddUIDToVerifySkipList(entryUID);
              ClearIOBuffer;
            end;
          end;
        finally
          if Assigned(AImap.IOHandler) then
            AImap.IOHandler.ReadTimeout := 60000;
          // 検証で選択フォルダが変わるため、次のメールの処理のために戻しておく
          AImap.SelectMailBox(FolderName);
        end;
      end
      else
        Log(Format(T('msg.verifySkipped'), [entryUID]));
    except
      on E: Exception do begin
        Log(Format(T('msg.processError'), [entryUID, E.Message]));
        ClearIOBuffer;
      end;
    end;
  end;
end;

{ 「メール削除」列にチェックが付いているメールを、丸ごと移動先フォルダへ退避
  （またはADeleteFolder=''なら完全削除）する処理の本体。添付は残したまま処理する点が
  「添付削除」との違い。AImapは呼び出し元が接続・SelectMailBox済みのものを渡す。 }
procedure TForm1.ProcessMailDeleteTargets(AImap: TIdIMAP4Batch; ATargets: TList<TMailEntry>;
  const ADeleteFolder: string; AIsGmail, AIsSpecialUseFolder: Boolean; out ATotalDeleted: Integer);
var
  entry: TMailEntry;
  entryUID: Int64;
  doneCount: Integer;
  ok: Boolean;
begin
  ATotalDeleted := 0;
  doneCount := 0;
  for entry in ATargets do begin
    entryUID := entry.UID;
    Inc(doneCount);
    UpdateProgress(doneCount, ATargets.Count,
      Format(T('msg.deleteMailsProgress'), [doneCount, ATargets.Count, entryUID]));
    try
      ok := MoveOrDeleteOriginal(entryUID, ADeleteFolder, AIsGmail, AIsSpecialUseFolder);
      if not ok then
        Log(Format(T('msg.preserveFailed'), [entryUID, ADeleteFolder]))
      else begin
        Inc(ATotalDeleted);
        if ADeleteFolder <> '' then
          Log(Format(T('msg.mailMoved'), [entryUID, ADeleteFolder]))
        else
          Log(Format(T('msg.mailDeleted'), [entryUID]));
        RemoveEntryFromList(entry);
      end;
    except
      on E: Exception do begin
        Log(Format(T('msg.processError'), [entryUID, E.Message]));
        ClearIOBuffer;
      end;
    end;
  end;
end;

{ 「添付削除」列・「メール削除」列、両方にチェックが付いたメールをまとめて1回で
  処理する統合ボタン。同じメールが両方にチェックされている場合は「メール削除」を
  優先する（メールごと消えるなら添付だけ抜く意味が無いため）。
  IMAP通信部分はすべてバックグラウンドスレッドで行い、メイン画面をブロックしない。
  確認ダイアログ・対象選定のみメインスレッドで同期的に行う。 }
procedure TForm1.DoProcessSelectedClick(Sender: TObject);
var
  i: Integer;
  entry: TMailEntry;
  attachTargets, mailTargets: TList<TMailEntry>;
  confirmMsg: string;
  deleteFolder: string;
  autoVerify: Boolean;
  th: TThread;
begin
  attachTargets := TList<TMailEntry>.Create;
  mailTargets := TList<TMailEntry>.Create;
  for i := 0 to lvMails.Items.Count - 1 do begin
    entry := TMailEntry(lvMails.Items[i].Data);
    if (not Assigned(entry)) or entry.IsProtected then Continue;
    if entry.MarkedForDelete then
      mailTargets.Add(entry)
    else if entry.MarkedForAttachDelete and (entry.AttachCount > 0) then
      attachTargets.Add(entry);
  end;

  if (attachTargets.Count = 0) and (mailTargets.Count = 0) then begin
    ShowMessage(T('msg.noTargets'));
    attachTargets.Free;
    mailTargets.Free;
    Exit;
  end;

  if not ConfirmBulkWarningIfNeeded(attachTargets.Count + mailTargets.Count) then begin
    attachTargets.Free;
    mailTargets.Free;
    Exit;
  end;

  deleteFolder := DeleteFolderName;
  if deleteFolder <> '' then
    confirmMsg := Format(T('msg.processConfirmMove'), [attachTargets.Count, mailTargets.Count, deleteFolder])
  else
    confirmMsg := Format(T('msg.processConfirmNoMove'), [attachTargets.Count, mailTargets.Count]);
  if MessageDlg(confirmMsg, mtWarning, [mbYes, mbNo], 0) <> mrYes then begin
    attachTargets.Free;
    mailTargets.Free;
    Exit;
  end;

  if not TryBeginNetworkOp then begin
    attachTargets.Free;
    mailTargets.Free;
    Exit;
  end;

  autoVerify := chkAutoVerify.Checked;

  Screen.Cursor := crHourGlass;
  btnUpdate.Enabled := False;
  btnList.Enabled := False;

  th := TThread.CreateAnonymousThread(
    procedure
    var
      imap: TIdIMAP4Batch;
      isGmail, isSpecialUseFolder: Boolean;
      totalAttachMails, totalRemoved, totalDeletedMails: Integer;
      errMsg: string;
    begin
      errMsg := '';
      totalAttachMails := 0;
      totalRemoved := 0;
      totalDeletedMails := 0;
      try
        try
          EnsureConnected;
          imap := FIMAP4;
          if not imap.SelectMailBox(FolderName) then
            raise Exception.Create(T('msg.folderSelectFailed'));

          isGmail := False;
          isSpecialUseFolder := False;
          if deleteFolder <> '' then begin
            isGmail := imap.IsGmailServer;

            if isGmail then begin
              // Gmailの「ゴミ箱」「迷惑メール」等の特殊フォルダは、ラベル追加では
              // 正しく移動できない（X-GM-LABELSの対象外で、別名のラベルが
              // 出来てしまうだけ）。これらは通常のCOPYコマンドでのみ移動できる。
              isSpecialUseFolder := imap.IsSpecialUseMailBox(deleteFolder);
            end;

            if not isSpecialUseFolder then begin
              // 移動先（添付付き原本の保管用）フォルダが指定されていれば、事前に作成しておく。
              // 既に存在する場合はサーバーがエラーを返すことがあるが、その場合は無視してよい。
              // （ゴミ箱等の特殊フォルダは作成対象外）
              try
                imap.CreateMailBox(deleteFolder);
              except
                // フォルダが既に存在する場合など。ここでは無視して続行する。
              end;
            end;

            if isGmail and (not isSpecialUseFolder) then
              // Gmailの通常ラベルの場合、標準IMAPの「COPYしてから元をDeletedフラグ+
              // EXPUNGE」という消し方をすると、複製先に残しているつもりでも元メールが
              // ゴミ箱へ落ちてしまうことがある。Gmail拡張のラベル操作(X-GM-LABELS)に
              // 切り替えることでこれを避ける。
              Log(T('msg.gmailLabelDetected'))
            else if isSpecialUseFolder then
              // ゴミ箱等の特殊フォルダの場合は、通常のCOPYで正しく移動できる
              // （むしろラベル操作では移動できないので、標準方式を使う）。
              Log(Format(T('msg.gmailSpecialFolder'), [deleteFolder]));
          end;

          if attachTargets.Count > 0 then
            ProcessAttachDeleteTargets(imap, attachTargets, deleteFolder,
              isGmail, isSpecialUseFolder, autoVerify, totalAttachMails, totalRemoved);

          if mailTargets.Count > 0 then
            ProcessMailDeleteTargets(imap, mailTargets, deleteFolder,
              isGmail, isSpecialUseFolder, totalDeletedMails);

          // 処理結果（キャッシュから取り除いた分）をファイルへ反映する
          SaveScanCache(PeekLastScannedUID);

          if (totalAttachMails > 0) or (totalDeletedMails > 0) then begin
            Log(T('msg.expunging'));
            imap.ExpungeMailBox;
          end
          else
            Log(T('msg.noProcessed'));
        except
          on E: Exception do begin
            Log(Format(T('msg.updateError'), [E.Message]));
            errMsg := E.Message;
          end;
        end;
      finally
        RunOnMainThread(
          procedure
          begin
            Screen.Cursor := crDefault;
            ResetProgress;
            btnUpdate.Enabled := True;
            btnList.Enabled := True;
            EndNetworkOp;
            attachTargets.Free;
            mailTargets.Free;

            if errMsg <> '' then
              ShowMessage(Format(T('msg.updateFailedBox'), [errMsg]))
            else if (totalAttachMails > 0) or (totalDeletedMails > 0) then
              ShowMessage(Format(T('msg.processDoneBox'), [totalAttachMails, totalRemoved, totalDeletedMails]));
            // 一覧は自動更新しない（処理済みの行を[済]表示のまま残し、その場で
            // 結果を見比べられるようにするため）。最新の状態を見たい場合は
            // 「一覧取得」を手動で押してもらう。
          end);
      end;
    end);
  th.FreeOnTerminate := True;
  th.Start;
end;

end.
