program imap_attachment_cleaner;



uses
  Vcl.Forms,
  Unit1 in 'Unit1.pas',
  LangUnit in 'LangUnit.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TForm1, Form1);
  Application.Run;
end.
