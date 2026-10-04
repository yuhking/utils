object Form1: TForm1
  Left = 580
  Top = 449
  Caption = 'IMAP'#28155#20184#12501#12449#12452#12523#21066#38500#12484#12540#12523
  ClientHeight = 597
  ClientWidth = 1260
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Tahoma'
  Font.Style = []
  OldCreateOrder = False
  Position = poScreenCenter
  OnClose = FormClose
  OnCreate = FormCreate
  PixelsPerInch = 96
  TextHeight = 14
  object pnlConn: TPanel
    Left = 0
    Top = 0
    Width = 321
    Height = 597
    Align = alLeft
    BevelOuter = bvNone
    TabOrder = 0
    DesignSize = (
      321
      597)
    object lblFolder: TLabel
      Left = 22
      Top = 288
      Width = 59
      Height = 14
      Caption = #23550#35937#12501#12457#12523#12480
    end
    object lblDeleteFolder: TLabel
      Left = 22
      Top = 378
      Width = 256
      Height = 14
      Caption = #31227#21205#20808#12501#12457#12523#12480'('#28155#20184#12501#12449#12452#12523#20184#12365#12398#20803#12513#12540#12523#12398#20445#31649#20808')'
    end
    object LabelDeleteAttachments: TLabel
      Left = 20
      Top = 421
      Width = 146
      Height = 14
      Caption = #8251#31354#27396#12394#12425#31227#21205#12379#12378#23436#20840#21066#38500
    end
    object lblStatus: TLabel
      Left = 22
      Top = 60
      Width = 36
      Height = 14
      Caption = #26410#25509#32154
    end
    object cboProfile: TComboBox
      Left = 20
      Top = 89
      Width = 242
      Height = 22
      TabOrder = 0
      OnChange = DoProfileChange
    end
    object btnSaveProfile: TButton
      Left = 204
      Top = 492
      Width = 106
      Height = 32
      Caption = '1. '#12371#12398#20869#23481#12391#30331#37682
      TabOrder = 1
      OnClick = DoSaveProfileClick
    end
    object btnDeleteProfile: TButton
      Left = 268
      Top = 89
      Width = 47
      Height = 23
      Caption = #21066#38500
      TabOrder = 2
      OnClick = DoDeleteProfileClick
    end
    object edtHost: TLabeledEdit
      Left = 20
      Top = 143
      Width = 242
      Height = 22
      EditLabel.Width = 117
      EditLabel.Height = 14
      EditLabel.Caption = 'IMAP'#12469#12540#12496#12540'('#12507#12473#12488#21517')'
      TabOrder = 3
    end
    object edtPort: TLabeledEdit
      Left = 268
      Top = 143
      Width = 47
      Height = 22
      EditLabel.Width = 28
      EditLabel.Height = 14
      EditLabel.Caption = #12509#12540#12488
      TabOrder = 4
      Text = '993'
    end
    object chkSSL: TCheckBox
      Left = 20
      Top = 171
      Width = 186
      Height = 16
      Caption = 'SSL/TLS'#12434#20351#12358
      Checked = True
      State = cbChecked
      TabOrder = 5
    end
    object edtUser: TLabeledEdit
      Left = 20
      Top = 213
      Width = 296
      Height = 22
      EditLabel.Width = 110
      EditLabel.Height = 14
      EditLabel.Caption = #12518#12540#12470#12540#21517'('#12525#12464#12452#12531'ID)'
      TabOrder = 6
    end
    object edtPass: TLabeledEdit
      Left = 20
      Top = 255
      Width = 296
      Height = 22
      EditLabel.Width = 47
      EditLabel.Height = 14
      EditLabel.Caption = #12497#12473#12527#12540#12489
      PasswordChar = '*'
      TabOrder = 7
    end
    object cboFolder: TComboBox
      Left = 22
      Top = 304
      Width = 149
      Height = 22
      TabOrder = 8
      Text = 'INBOX'
    end
    object btnListFolders: TButton
      Left = 180
      Top = 303
      Width = 103
      Height = 23
      Caption = #12501#12457#12523#12480#19968#35239#21462#24471
      TabOrder = 9
      OnClick = DoListFoldersClick
    end
    object edtMaxCount: TLabeledEdit
      Left = 22
      Top = 348
      Width = 84
      Height = 22
      EditLabel.Width = 245
      EditLabel.Height = 14
      EditLabel.Caption = #28155#20184#12501#12449#12452#12523#20184#12365#12434#20309#20214#35211#12388#12369#12427#12414#12391#26908#32034'(0='#20840#20214')'
      TabOrder = 10
      Text = '50'
    end
    object cboDeleteFolder: TComboBox
      Left = 22
      Top = 394
      Width = 295
      Height = 22
      TabOrder = 12
      Text = 'DeletedAttachments'
    end
    object btnConnect: TButton
      Left = 20
      Top = 7
      Width = 107
      Height = 40
      Caption = '2. '#25509#32154
      Default = True
      TabOrder = 11
      OnClick = DoConnectClick
    end
    object btnLanguage: TButton
      Left = 20
      Top = 565
      Width = 107
      Height = 24
      Anchors = [akLeft, akBottom]
      Caption = 'English'
      TabOrder = 13
      OnClick = DoLanguageChange
    end
    object chkAutoConnect: TCheckBox
      Left = 20
      Top = 450
      Width = 290
      Height = 17
      Caption = 'Auto-connect on startup'
      TabOrder = 14
      OnClick = DoAutoConnectClick
    end
    object chkAutoList: TCheckBox
      Left = 20
      Top = 469
      Width = 290
      Height = 17
      Caption = 'Auto-fetch list after connecting'
      Checked = True
      State = cbChecked
      TabOrder = 15
      OnClick = DoAutoListClick
    end
    object chkAutoVerify: TCheckBox
      Left = 20
      Top = 530
      Width = 290
      Height = 17
      Caption = 'Auto-verify after each removal'
      Checked = True
      State = cbChecked
      TabOrder = 16
      OnClick = DoAutoVerifyClick
    end
  end
  object pList: TPanel
    Left = 321
    Top = 0
    Width = 939
    Height = 597
    Align = alClient
    TabOrder = 1
    object memoLog: TMemo
      Left = 1
      Top = 475
      Width = 937
      Height = 121
      Align = alBottom
      ReadOnly = True
      ScrollBars = ssVertical
      TabOrder = 0
    end
    object lvMails: TListView
      Left = 1
      Top = 47
      Width = 937
      Height = 428
      Align = alClient
      Columns = <
        item
          Caption = #28155#20184#21066#38500
          Width = 70
        end
        item
          Caption = #12513#12540#12523#21066#38500
          Width = 70
        end
        item
          Caption = #20445#35703
          Width = 50
        end
        item
          Caption = #26085#20184
          Width = 131
        end
        item
          Caption = #24046#20986#20154
          Width = 187
        end
        item
          Caption = #20214#21517
          Width = 280
        end
        item
          Caption = #28155#20184#25968
          Width = 56
        end
        item
          Caption = #28155#20184#21512#35336#12469#12452#12474
          Width = 93
        end>
      GridLines = True
      ReadOnly = True
      RowSelect = True
      TabOrder = 1
      ViewStyle = vsReport
      OnColumnClick = DoColumnClick
      OnCompare = DoCompareItems
      OnDblClick = DoMailsDblClick
      OnMouseDown = DoMailsMouseDown
    end
    object topPanel: TPanel
      Left = 1
      Top = 1
      Width = 937
      Height = 46
      Align = alTop
      BevelOuter = bvNone
      TabOrder = 2
      object lblProgress: TLabel
        Left = 117
        Top = 29
        Width = 57
        Height = 14
        Caption = 'lblProgress'
      end
      object btnList: TButton
        Left = 5
        Top = 7
        Width = 93
        Height = 33
        Caption = '3. '#19968#35239#21462#24471
        Enabled = False
        TabOrder = 0
        OnClick = DoListMails
      end
      object btnUpdate: TButton
        Left = 510
        Top = 7
        Width = 306
        Height = 33
        Caption = '4. '#36984#25246#12375#12383#39033#30446#12434#21762#29702
        Enabled = False
        TabOrder = 1
        OnClick = DoProcessSelectedClick
      end
      object pbProgress: TProgressBar
        Left = 117
        Top = 7
        Width = 371
        Height = 21
        TabOrder = 2
      end
      object btnClearCache: TButton
        Left = 824
        Top = 6
        Width = 108
        Height = 34
        Caption = #26908#32034#12461#12515#12483#12471#12517#12434#12463#12522#12450
        TabOrder = 3
        OnClick = DoClearCacheClick
      end
    end
  end
end
