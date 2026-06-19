package conf

const (
	TypeString = "string"
	TypeSelect = "select"
	TypeBool   = "bool"
	TypeText   = "text"
	TypeNumber = "number"
)

const (
	// site
	VERSION      = "version"
	SiteTitle    = "site_title"
	Announcement = "announcement"
	AllowIndexed = "allow_indexed"
	AllowMounted = "allow_mounted"
	RobotsTxt    = "robots_txt"

	// preview
	TextTypes                = "text_types"
	AudioTypes               = "audio_types"
	VideoTypes               = "video_types"
	ImageTypes               = "image_types"
	ProxyTypes               = "proxy_types"
	ProxyIgnoreHeaders       = "proxy_ignore_headers"
	AudioAutoplay            = "audio_autoplay"
	VideoAutoplay            = "video_autoplay"
	PreviewDownloadByDefault = "preview_download_by_default"
	ReadMeAutoRender         = "readme_autorender"
	FilterReadMeScripts      = "filter_readme_scripts"

	// global
	HideFiles               = "hide_files"
	CustomizeHead           = "customize_head"
	CustomizeBody           = "customize_body"
	LinkExpiration          = "link_expiration"
	SignAll                 = "sign_all"
	PrivacyRegs             = "privacy_regs"
	OcrApi                  = "ocr_api"
	FilenameCharMapping     = "filename_char_mapping"
	ForwardDirectLinkParams = "forward_direct_link_params"
	IgnoreDirectLinkParams  = "ignore_direct_link_params"
	WebauthnLoginEnabled    = "webauthn_login_enabled"
	HandleHookAfterWriting  = "handle_hook_after_writing"
	HandleHookRateLimit     = "handle_hook_rate_limit"
	IgnoreSystemFiles       = "ignore_system_files"

	// index
	SearchIndex     = "search_index"
	AutoUpdateIndex = "auto_update_index"
	IgnorePaths     = "ignore_paths"
	MaxIndexDepth   = "max_index_depth"

	// aria2
	Aria2Uri    = "aria2_uri"
	Aria2Secret = "aria2_secret"

	// transmission
	TransmissionUri      = "transmission_uri"
	TransmissionSeedtime = "transmission_seedtime"

	// pikpak
	PikPakTempDir = "pikpak_temp_dir"

	// single
	Token         = "token"
	IndexProgress = "index_progress"

	// qbittorrent
	QbittorrentUrl      = "qbittorrent_url"
	QbittorrentSeedtime = "qbittorrent_seedtime"

	// ftp
	FTPPublicHost            = "ftp_public_host"
	FTPPasvPortMap           = "ftp_pasv_port_map"
	FTPMandatoryTLS          = "ftp_mandatory_tls"
	FTPImplicitTLS           = "ftp_implicit_tls"
	FTPTLSPrivateKeyPath     = "ftp_tls_private_key_path"
	FTPTLSPublicCertPath     = "ftp_tls_public_cert_path"
	SFTPDisablePasswordLogin = "sftp_disable_password_login"

	// traffic
	TaskOfflineDownloadThreadsNum         = "offline_download_task_threads_num"
	TaskOfflineDownloadTransferThreadsNum = "offline_download_transfer_task_threads_num"
	TaskUploadThreadsNum                  = "upload_task_threads_num"
	TaskCopyThreadsNum                    = "copy_task_threads_num"
	TaskMoveThreadsNum                    = "move_task_threads_num"
	StreamMaxClientDownloadSpeed          = "max_client_download_speed"
	StreamMaxClientUploadSpeed            = "max_client_upload_speed"
	StreamMaxServerDownloadSpeed          = "max_server_download_speed"
	StreamMaxServerUploadSpeed            = "max_server_upload_speed"
	ProxyDownloadConcurrency              = "proxy_download_concurrency"
)

const (
	UNKNOWN = iota
	FOLDER
	// OFFICE
	VIDEO
	AUDIO
	TEXT
	IMAGE
)

// ContextKey is the type of context keys.
type ContextKey int8

const (
	_ ContextKey = iota

	NoTaskKey
	ApiUrlKey
	UserKey
	MetaKey
	MetaPassKey
	ClientIPKey
	ProxyHeaderKey
	RequestHeaderKey
	UserAgentKey
	PathKey
	SharingIDKey
	SkipHookKey
)
