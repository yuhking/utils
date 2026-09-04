unit LangUnit;

{
  外部の言語ファイル（lang_ja.ini / lang_en.ini, UTF-8, "キー=値" 形式）を
  読み込んで文字列を切り替えるだけの、簡易な多言語化ユニット。
  ファイルが無い/キーが無い場合はキー名をそのまま返す（表示が壊れないため）。
}

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, System.IniFiles;

var
  CurrentLangCode: string;

procedure SetLanguage(const ACode: string);
function T(const AKey: string): string;

implementation

var
  FStrings: TDictionary<string, string>;

function LangFilePath(const ACode: string): string;
begin
  Result := ExtractFilePath(ParamStr(0)) + 'lang_' + ACode + '.ini';
end;

procedure SetLanguage(const ACode: string);
var
  fname: string;
  ini: TMemIniFile;
  names: TStringList;
  i: Integer;
begin
  CurrentLangCode := ACode;
  fname := LangFilePath(ACode);

  if not Assigned(FStrings) then
    FStrings := TDictionary<string, string>.Create
  else
    FStrings.Clear;

  if not FileExists(fname) then Exit;

  // UTF-8で明示的に読む（TIniFileのWin32プロファイルAPI経由だと
  // 環境のANSIコードページに依存して日本語が化ける場合があるため）。
  ini := TMemIniFile.Create(fname, TEncoding.UTF8);
  names := TStringList.Create;
  try
    ini.ReadSection('Strings', names); {Do not Localize}
    for i := 0 to names.Count - 1 do
      FStrings.AddOrSetValue(names[i], ini.ReadString('Strings', names[i], names[i])); {Do not Localize}
  finally
    names.Free;
    ini.Free;
  end;
end;

function T(const AKey: string): string;
begin
  if (not Assigned(FStrings)) or (not FStrings.TryGetValue(AKey, Result)) then
    Result := AKey;
end;

initialization

finalization
  FStrings.Free;

end.
