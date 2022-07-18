Red/System [
	Title:   "TLS support on Windows"
	Author:  "Xie Qingtian"
	File:	 %tls.reds
	Tabs:	 4
	Rights:  "Copyright (C) 2014-2018 Red Foundation. All rights reserved."
	License: {
		Distributed under the Boost Software License, Version 1.0.
		See https://github.com/red/red/blob/master/BSL-License.txt
	}
]

#define MAX_SSL_MSG_LENGTH				17408
#define SEC_OK							0
#define SEC_I_CONTINUE_NEEDED			00090312h
#define SEC_E_INCOMPLETE_MESSAGE		80090318h
#define SEC_E_INCOMPLETE_CREDENTIALS	00090320h
#define SEC_I_RENEGOTIATE				00090321h

#define ECC_256_MAGIC_NUMBER			20h
#define ECC_384_MAGIC_NUMBER			30h
#define BCRYPT_ECDSA_PRIVATE_P256_MAGIC 32534345h  ;-- ECS2
#define BCRYPT_ECDSA_PRIVATE_P384_MAGIC 34534345h  ;-- ECS4
#define BCRYPT_ECDSA_PRIVATE_P521_MAGIC 36534345h  ;-- ECS6

#define CERT_STORE_PROV_MEMORY			02h
#define CRYPT_STRING_BASE64HEADER		00h
#define X509_ASN_ENCODING				01h
#define PKCS_7_ASN_ENCODING				00010000h
#define PKCS_RSA_PRIVATE_KEY			43
#define X509_ECC_PRIVATE_KEY			82
#define CERT_STORE_ADD_NEW				1
#define CNG_RSA_PRIVATE_KEY_BLOB		83
#define CERT_STORE_ADD_REPLACE_EXISTING	3
#define CERT_STORE_ADD_ALWAYS			4
#define CERT_SYSTEM_STORE_LOCAL_MACHINE	[2 << 16]
#define CERT_SYSTEM_STORE_CURRENT_USER	[1 << 16]

#define SP_PROT_SSL3_SERVER				00000010h
#define SP_PROT_SSL3_CLIENT				00000020h
#define SP_PROT_TLS1_SERVER				00000040h
#define SP_PROT_TLS1_CLIENT				00000080h
#define SP_PROT_TLS1_1_SERVER			00000100h
#define SP_PROT_TLS1_1_CLIENT			00000200h
#define SP_PROT_TLS1_2_SERVER			00000400h
#define SP_PROT_TLS1_2_CLIENT			00000800h
#define SP_PROT_TLS1_3_SERVER			00001000h
#define SP_PROT_TLS1_3_CLIENT			00002000h

#define SP_PROT_DEFAULT_SERVER			[SP_PROT_TLS1_2_SERVER or SP_PROT_TLS1_3_SERVER]
#define SP_PROT_DEFAULT_CLINET			[SP_PROT_TLS1_2_CLIENT or SP_PROT_TLS1_3_CLIENT]

#define USAGE_MATCH_TYPE_OR				00000001h

#define CERT_CHAIN_CACHE_END_CERT		00000001h
#define CERT_CHAIN_REVOCATION_CHECK_CACHE_ONLY 80000000h
#define CERT_CHAIN_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT 40000000h


#define CERT_CHAIN_POLICY_ALLOW_UNKNOWN_CA_FLAG 00000010h
#define CERT_CHAIN_POLICY_IGNORE_END_REV_UNKNOWN_FLAG 00000100h
#define CERT_CHAIN_POLICY_IGNORE_CTL_SIGNER_REV_UNKNOWN_FLAG 00000200h
#define CERT_CHAIN_POLICY_IGNORE_CA_REV_UNKNOWN_FLAG 00000400h
#define CERT_CHAIN_POLICY_IGNORE_ROOT_REV_UNKNOWN_FLAG 00000800h
#define CERT_CHAIN_POLICY_IGNORE_ALL_REV_UNKNOWN_FLAGS [
	CERT_CHAIN_POLICY_IGNORE_END_REV_UNKNOWN_FLAG or
	CERT_CHAIN_POLICY_IGNORE_CTL_SIGNER_REV_UNKNOWN_FLAG or
	CERT_CHAIN_POLICY_IGNORE_CA_REV_UNKNOWN_FLAG or
	CERT_CHAIN_POLICY_IGNORE_ROOT_REV_UNKNOWN_FLAG
]

#define CERT_CHAIN_POLICY_SSL			4

#define SecIsValidHandle(x)	[
	all [x/dwLower <> (as int-ptr! -1) x/dwUpper <> (as int-ptr! -1)]
]

tls: context [
	verbose: 0

	cert-client: as CERT_CONTEXT 0
	cert-server: as CERT_CONTEXT 0
	user-store: as int-ptr! 0
	machine-store: as int-ptr! 0

	sspi-flags-client: ISC_REQ_SEQUENCE_DETECT or
		ISC_REQ_REPLAY_DETECT or
		ISC_REQ_CONFIDENTIALITY or
		ISC_REQ_EXTENDED_ERROR or
		ISC_REQ_MANUAL_CRED_VALIDATION or
		ISC_REQ_STREAM

	sspi-flags-server: ISC_REQ_SEQUENCE_DETECT or
		ISC_REQ_REPLAY_DETECT or
		ISC_REQ_CONFIDENTIALITY or
		ASC_REQ_EXTENDED_ERROR or
		ASC_REQ_STREAM


	pem-to-binary: func [
		str			[c-string!]
		len			[integer!]
		blen		[int-ptr!]
		return:		[byte-ptr!]						;-- after used, please free it
		/local
			etype	[integer!]
			buff	[byte-ptr!]
	][
		etype: CRYPT_STRING_BASE64HEADER
		blen/value: 0
		unless CryptStringToBinaryA str len etype null blen null null [
			return null
		]
		buff: allocate blen/value
		unless CryptStringToBinaryA str len etype buff blen null null [
			free buff
			return null
		]
		buff
	]

	decode-key: func [
		key			[red-string!]
		klen		[int-ptr!]
		type		[int-ptr!]
		return:		[byte-ptr!]
		/local
			len		[integer!]
			str		[c-string!]
			blen	[integer!]
			buff	[byte-ptr!]
			etype	[integer!]
			blob	[byte-ptr!]
	][
		len: -1
		str: unicode/to-utf8 key :len

		blen: 0
		buff: pem-to-binary str len :blen
		if null? buff [return null]

		klen/value: 0
		etype: X509_ASN_ENCODING or PKCS_7_ASN_ENCODING
		type/value: CNG_RSA_PRIVATE_KEY_BLOB
		unless CryptDecodeObjectEx etype type/value buff blen 0 null null klen [
			type/value: X509_ECC_PRIVATE_KEY
			unless CryptDecodeObjectEx etype type/value buff blen 0 null null klen [
				free buff
				return null
			]
		]
		blob: allocate klen/value
		unless CryptDecodeObjectEx etype type/value buff blen 0 null blob klen [
			free buff
			return null
		]
		free buff
		blob
	]

	link-rsa-key: func [
		ctx			[CERT_CONTEXT]
		blob		[byte-ptr!]
		size		[integer!]
		return:		[integer!]
		/local
			provider	[integer!]
			prov-name	[c-string!]
			type-str	[c-string!]
			cont-name	[c-string!]
			nc-buf		[BCryptBuffer! value]
			nc-desc		[BCryptBufferDesc! value]
			h-key		[integer!]
			status		[integer!]
			prov-info	[CRYPT_KEY_PROV_INFO value]
	][
		provider: 0
		prov-name: #u16 "Microsoft Software Key Storage Provider"
		if 0 <> NCryptOpenStorageProvider :provider prov-name 0 [
			return 2
		]
		type-str: #u16 "RSAPRIVATEBLOB"
		cont-name: #u16 "RedRSAKey"
		nc-buf/cbBuffer: 10 * 2				;-- bytes of the pvBuffer
		nc-buf/BufferType: 45				;-- NCRYPTBUFFER_PKCS_KEY_NAME
		nc-buf/pvBuffer: as byte-ptr! cont-name
		nc-desc/ulVersion: 0
		nc-desc/cBuffers: 1
		nc-desc/pBuffers: nc-buf

		h-key: 0
		status: NCryptImportKey
			as int-ptr! provider
			null
			type-str
			as int-ptr! :nc-desc
			:h-key
			blob
			size
			80h								;-- NCRYPT_OVERWRITE_KEY_FLAG
		NCryptFreeObject as int-ptr! provider
		if status = 0 [
			NCryptFreeObject as int-ptr! h-key
			zero-memory as byte-ptr! :prov-info size? CRYPT_KEY_PROV_INFO
			prov-info/pwszContainerName: cont-name
			prov-info/pwszProvName: prov-name
			unless CertSetCertificateContextProperty ctx 2 0 as byte-ptr! :prov-info [
				status: 3
			]
		]

		status
	]

	link-ecc-key: func [
		ctx			[CERT_CONTEXT]
		blob		[byte-ptr!]
		size		[integer!]
		return:		[integer!]
		/local
			pub-blob	[CRYPT_BIT_BLOB]
			key-info	[CRYPT_ECC_PRIVATE_KEY_INFO]
			pub-size	[integer!]
			priv-size	[integer!]
			blob-size	[integer!]
			pub-buf		[byte-ptr!]
			priv-buf	[byte-ptr!]
			key-blob	[BCRYPT_ECCKEY_BLOB]
			provider	[integer!]
			prov-name	[c-string!]
			type-str	[c-string!]
			cont-name	[c-string!]
			nc-buf		[BCryptBuffer! value]
			nc-desc		[BCryptBufferDesc! value]
			h-key		[integer!]
			status		[integer!]
			prov-info	[CRYPT_KEY_PROV_INFO value]
	][
		pub-blob: ctx/pCertInfo/SubjectPublicKeyInfo/PublicKey
		key-info: as CRYPT_ECC_PRIVATE_KEY_INFO blob
		pub-size: pub-blob/cbData - 1
		priv-size: key-info/PrivateKey/cbData
		blob-size: pub-size + priv-size + size? BCRYPT_ECCKEY_BLOB
		pub-buf: pub-blob/pbData + 1
		priv-buf: key-info/PrivateKey/pbData
		key-blob: as BCRYPT_ECCKEY_BLOB allocate blob-size
		;-- print-line ["size: " size " priv: " priv-size " pub: " pub-size]

		if null? key-blob [return 1]

		key-blob/dwMagic: switch priv-size [
			ECC_256_MAGIC_NUMBER [BCRYPT_ECDSA_PRIVATE_P256_MAGIC]
			ECC_384_MAGIC_NUMBER [BCRYPT_ECDSA_PRIVATE_P384_MAGIC]
			default [BCRYPT_ECDSA_PRIVATE_P521_MAGIC]
		]
		key-blob/cbKey: priv-size
		copy-memory as byte-ptr! (key-blob + 1) pub-buf pub-size
		copy-memory (as byte-ptr! key-blob + 1) + pub-size priv-buf priv-size

		provider: 0
		prov-name: #u16 "Microsoft Software Key Storage Provider"
		if 0 <> NCryptOpenStorageProvider :provider prov-name 0 [
			free as byte-ptr! key-blob
			return 2
		]

		type-str: #u16 "ECCPRIVATEBLOB"
		cont-name: #u16 "RedECCKey"
		nc-buf/cbBuffer: 10 * 2				;-- bytes of the pvBuffer
		nc-buf/BufferType: 45				;-- NCRYPTBUFFER_PKCS_KEY_NAME
		nc-buf/pvBuffer: as byte-ptr! cont-name
		nc-desc/ulVersion: 0
		nc-desc/cBuffers: 1
		nc-desc/pBuffers: nc-buf

		h-key: 0
		status: NCryptImportKey
			as int-ptr! provider
			null
			type-str
			as int-ptr! :nc-desc
			:h-key
			as byte-ptr! key-blob
			blob-size
			80h								;-- NCRYPT_OVERWRITE_KEY_FLAG
		NCryptFreeObject as int-ptr! provider
		if status = 0 [
			NCryptFreeObject as int-ptr! h-key
			zero-memory as byte-ptr! :prov-info size? CRYPT_KEY_PROV_INFO
			prov-info/pwszContainerName: cont-name
			prov-info/pwszProvName: prov-name
			unless CertSetCertificateContextProperty ctx 2 0 as byte-ptr! :prov-info [
				status: 3
			]
		]

		free as byte-ptr! key-blob
		status
	]

	load-cert: func [
		cert		[red-string!]
		return:		[CERT_CONTEXT]
		/local
			len		[integer!]
			str		[c-string!]
			blen	[integer!]
			buff	[byte-ptr!]
			etype	[integer!]
			ctx		[CERT_CONTEXT]
	][
		len: -1
		str: unicode/to-utf8 cert :len

		blen: 0
		buff: pem-to-binary str len :blen
		if null? buff [return null]

		etype: X509_ASN_ENCODING or PKCS_7_ASN_ENCODING
		ctx: CertCreateCertificateContext etype buff blen
		if null? ctx [
			free buff
			return null
		]
		free buff
		ctx
	]

	save-cert: func [
		cert		[CERT_CONTEXT]
		return:		[logic!]
		/local
			flags	[integer!]
			store	[int-ptr!]
	][
		flags: CERT_SYSTEM_STORE_CURRENT_USER
		store: CertOpenStore 10 0 null flags #u16 "My"
		if null? store [return false]
		unless CertAddCertificateContextToStore store cert CERT_STORE_ADD_REPLACE_EXISTING null [
			return false
		]
		CertCloseStore store 0
	]

	link-private-key: func [
		ctx			[CERT_CONTEXT]
		key			[red-string!]
		pwd			[red-string!]
		return:		[integer!]
		/local
			klen	[integer!]
			type	[integer!]
			pkey	[byte-ptr!]
			ret		[integer!]
	][
		klen: 0 type: 0
		pkey: decode-key key :klen :type
		ret: -1
		unless null? pkey [
			ret: either type = X509_ECC_PRIVATE_KEY [
				link-ecc-key ctx pkey klen
			][
				link-rsa-key ctx pkey klen
			]
			;-- print-line ["link-private-key: " as int-ptr! ret]
			free pkey
		]
		ret
	]

	store-identity: func [
		data		[tls-data!]
		return:		[logic!]
		/local
			values	[red-value!]
			extra	[red-block!]
			certs	[red-block!]
			head	[red-string!]
			tail	[red-string!]
			first	[CERT_CONTEXT]
			ctx		[CERT_CONTEXT]
			key		[red-string!]
			pwd		[red-string!]
	][
		values: object/get-values data/port
		extra: as red-block! values + port/field-extra
		if TYPE_OF(extra) <> TYPE_BLOCK [return false]
		certs: as red-block! block/select-word extra word/load "certs" no
		if TYPE_OF(certs) <> TYPE_BLOCK [return false]
		head: as red-string! block/rs-head certs
		tail: as red-string! block/rs-tail certs
		first: null
		while [head < tail][
			if TYPE_OF(head) = TYPE_STRING [
				ctx: load-cert head
				if null? ctx [
					IODebug("load cert failed!!!")
					return false
				]
				either null? first [
					first: ctx
					data/cert-ctx: ctx
					key: as red-string! block/select-word extra word/load "key" no
					pwd: as red-string! block/select-word extra word/load "password" no
					if 0 <> link-private-key ctx key pwd [
						IODebug("link key failed!!!")
						return false
					]
				][
					save-cert ctx
					CertFreeCertificateContext ctx
				]
			]
			head: head + 1
		]
		first <> null
	]

	store-roots: func [
		data		[tls-data!]
		return:		[logic!]
		/local
			values	[red-value!]
			extra	[red-block!]
			certs	[red-block!]
			store	[handle!]
			head	[red-string!]
			tail	[red-string!]
			ctx		[CERT_CONTEXT]
			roots	[red-block!]
	][
		values: object/get-values data/port
		extra: as red-block! values + port/field-extra
		if TYPE_OF(extra) <> TYPE_BLOCK [return false]
		roots: as red-block! block/select-word extra word/load "roots" no
		if TYPE_OF(roots) = TYPE_BLOCK [
			store: CertOpenStore 2 0 null 0 null				;-- CERT_STORE_PROV_MEMORY
			if null? store [return false]
			head: as red-string! block/rs-head roots
			tail: as red-string! block/rs-tail roots
			while [head < tail][
				if TYPE_OF(head) = TYPE_STRING [
					ctx: load-cert head
					if null? ctx [
						IODebug("load cert failed!!!")
						return false
					]
					unless CertAddCertificateContextToStore store ctx CERT_STORE_ADD_REPLACE_EXISTING null [
						IODebug("store cert failed!!!")
						return false
					]
					CertFreeCertificateContext ctx
				]
				head: head + 1
			]
			if null? ctx [
				CertCloseStore store 0
				return false
			]
			data/root-store: store
		]
		true
	]

	ctx-equal?: func [
		ctx1		[CERT_CONTEXT]
		ctx2		[CERT_CONTEXT]
		return:		[logic!]
	][
		if ctx1/cbCertEncoded <> ctx2/cbCertEncoded [return false]
		0 = compare-memory ctx1/pbCertEncoded ctx2/pbCertEncoded ctx1/cbCertEncoded
	]

	find-ctx?: func [
		store		[handle!]
		cmp			[CERT_CONTEXT]
		return:		[logic!]
		/local
			ctx		[CERT_CONTEXT]
	][
		ctx: null
		while [
			ctx: CertEnumCertificatesInStore store ctx
			not null? ctx
		][
			if ctx-equal? ctx cmp [
				return true
			]
		]
		false
	]

	get-domain: func [
		data		[tls-data!]
		return:		[c-string!]
		/local
			values	[red-value!]
			extra	[red-block!]
			domain	[red-string!]
	][
		values: object/get-values data/port
		extra: as red-block! values + port/field-extra
		if TYPE_OF(extra) <> TYPE_BLOCK [return null]
		domain: as red-string! block/select-word extra word/load "domain" no
		if TYPE_OF(domain) <> TYPE_STRING [return null]
		unicode/to-utf16 domain
	]

	default-protocol: func [
		client?		[logic!]
		return:		[integer!]
	][
		0		;-- depends on the settings in registry
	]

	proto2flag: func [
		client?		[logic!]
		proto		[integer!]
		return:		[integer!]
	][
		case [
			proto = 0300h [
				either client? [SP_PROT_SSL3_CLIENT][SP_PROT_SSL3_SERVER]
			]
			proto = 0301h [
				either client? [SP_PROT_TLS1_CLIENT][SP_PROT_TLS1_SERVER]
			]
			proto = 0302h [
				either client? [SP_PROT_TLS1_1_CLIENT][SP_PROT_TLS1_1_SERVER]
			]
			proto = 0303h [
				either client? [SP_PROT_TLS1_2_CLIENT][SP_PROT_TLS1_2_SERVER]
			]
			proto = 0304h [
				either client? [SP_PROT_TLS1_3_CLIENT][SP_PROT_TLS1_3_SERVER]
			]
		]
	]

	protocol-flags: func [
		data		[tls-data!]
		client?		[logic!]
		return:		[integer!]
		/local
			values	[red-value!]
			extra	[red-block!]
			minp	[red-integer!]
			maxp	[red-integer!]
			min		[integer!]
			max		[integer!]
			flags	[integer!]
	][
		values: object/get-values data/port
		extra: as red-block! values + port/field-extra
		if TYPE_OF(extra) <> TYPE_BLOCK [
			return default-protocol client?
		]
		minp: as red-integer! block/select-word extra word/load "min-protocol" no
		maxp: as red-integer! block/select-word extra word/load "max-protocol" no
		if any [
			all [
				TYPE_OF(minp) <> TYPE_INTEGER
				TYPE_OF(maxp) <> TYPE_INTEGER
			]
			all [
				TYPE_OF(minp) = TYPE_INTEGER
				minp/value > 0304h
			]
			all [
				TYPE_OF(maxp) = TYPE_INTEGER
				maxp/value < 0300h
			]
			all [
				TYPE_OF(minp) = TYPE_INTEGER
				TYPE_OF(maxp) = TYPE_INTEGER
				minp/value > maxp/value
			]
		][
			return default-protocol client?
		]
		min: either TYPE_OF(minp) <> TYPE_INTEGER [0300h][minp/value]
		max: either TYPE_OF(maxp) <> TYPE_INTEGER [0304h][maxp/value]
		flags: 0
		until [
			flags: flags or proto2flag client? min
			min: min + 1
			min > max
		]
		flags
	]


	create-credentials: func [
		data		[tls-data!]
		client?		[logic!]			;-- Is it client side?
		return:		[integer!]			;-- return status code
		/local
			ctx		[integer!]
			scred	[SCHANNEL_CRED value]
			status	[integer!]
			expiry	[tagFILETIME value]
			flags	[integer!]
	][
		zero-memory as byte-ptr! :scred size? SCHANNEL_CRED
		scred/dwVersion: 4		;-- SCHANNEL_CRED_VERSION

		ctx: as integer! data/cert-ctx
		if all [
			ctx = 0
			store-identity data
		][
			ctx: as integer! data/cert-ctx
		]
		if ctx <> 0 [
			scred/cCreds: 1
			scred/paCred: :ctx
		]
		
		scred/dwFlags: SCH_USE_STRONG_CRYPTO
		scred/grbitEnabledProtocols: protocol-flags data client?
		;print-line ["protos: " as int-ptr! scred/grbitEnabledProtocols]

		either client? [flags: 2][flags: 1]		;-- Credential use flags
		status: platform/SSPI/AcquireCredentialsHandleW
			null		;-- name of principal
			#u16 "Microsoft Unified Security Protocol Provider"
			flags
			null
			as int-ptr! :scred
			null
			null
			as SecHandle! :data/credential
			:expiry

		if status <> 0 [
			flags: status
			status: GetLastError
			probe ["status error: " as int-ptr! flags " " as int-ptr! status]
			either status = 8009030Dh [		;-- SEC_E_UNKNOWN_CREDENTIALS
				status: -1					;-- needs administrator rights
			][
				status: -2
			]
		]
		status
	]

	create: func [
		data		[tls-data!]
		/local
			buf		[red-binary!]
	][
		buf: as red-binary! (object/get-values data/port) + port/field-data
		if TYPE_OF(buf) <> TYPE_BINARY [
			binary/make-at as cell! buf MAX_SSL_MSG_LENGTH * 4
		]
		data/send-buf: buf/node
	]

	release-context: func [
		data	[tls-data!]
	][
		if SecIsValidHandle(data/credential) [
			platform/SSPI/FreeCredentialsHandle data/credential
		]
		platform/SSPI/DeleteSecurityContext :data/security
	]

	merge-store: func [
		from		[handle!]
		to			[handle!]
		/local
			ctx		[CERT_CONTEXT]
	][
		ctx: null
		while [
			ctx: CertEnumCertificatesInStore from ctx
			not null? ctx
		][
			unless CertAddCertificateContextToStore to ctx CERT_STORE_ADD_REPLACE_EXISTING null [
				IODebug("merge cert failed!!!")
				continue
			]
		]
	]

	print-ctx: func [
		ctx		[CERT_CONTEXT]
		/local
			buf	[c-string!]
	][
		buf: as c-string! system/stack/allocate 64
		CertGetNameStringA ctx 4 0 null buf 256
		print-line buf
	]

	validate?: func [
		data		[tls-data!]
		sec-handle	[SecHandle!]
		return:		[logic!]
		/local
			values		[red-value!]
			extra		[red-block!]
			invalid?	[red-logic!]
			builtin?	[red-logic!]
			not-sys		[logic!]
			rctx		[integer!]
			ret			[integer!]
			ctx			[CERT_CONTEXT]
			rstore		[handle!]
			store		[handle!]
			para		[CERT_CHAIN_PARA value]
			flags		[integer!]
			user?		[logic!]
			ids			[int-ptr!]
			cert-chain	[integer!]
			chain		[CERT_CHAIN_CONTEXT]
			last-chain	[CERT_SIMPLE_CHAIN]
			index		[integer!]
			elem-n		[integer!]
			elem		[int-ptr!]
			elem-p		[CERT_CHAIN_ELEMENT]
			extra_para	[HTTPSPolicyCallbackData value]
			domain		[red-string!]
			policy		[CERT_CHAIN_POLICY_PARA value]
			status		[CERT_CHAIN_POLICY_STATUS value]
	][
		values: object/get-values data/port
		extra: as red-block! values + port/field-extra
		if TYPE_OF(extra) <> TYPE_BLOCK [return false]
		invalid?: as red-logic! block/select-word extra word/load "accept-invalid-cert" no
		if all [
			TYPE_OF(invalid?) = TYPE_LOGIC
			invalid?/value
		][return true]
		builtin?: as red-logic! block/select-word extra word/load "disable-builtin-roots" no
		either all [
			TYPE_OF(builtin?) = TYPE_LOGIC
			builtin?/value
		][not-sys: true][not-sys: false]
		if all [
			not-sys
			null? data/root-store
		][return false]
		rctx: 0
		ret: platform/SSPI/QueryContextAttributesW
			sec-handle
			53h			;-- SECPKG_ATTR_REMOTE_CERT_CONTEXT
			as byte-ptr! :rctx
		if ret <> 0 [return false]
		if rctx = 0 [return false]
		ctx: as CERT_CONTEXT rctx
		rstore: ctx/hCertStore
		either null? rstore [
			store: CertOpenStore 2 0 null 0 null				;-- CERT_STORE_PROV_MEMORY
		][
			store: CertDuplicateStore rstore
		]
		unless null? data/root-store [
			merge-store data/root-store store
		]
		set-memory as byte-ptr! para null-byte size? CERT_CHAIN_PARA
		para/cbSize: size? CERT_CHAIN_PARA
		para/usage/type: USAGE_MATCH_TYPE_OR
		ids: system/stack/allocate 3
		ids/1: as integer! "1.3.6.1.5.5.7.3.1"
		ids/2: as integer! "1.3.6.1.4.1.311.10.3.3"
		ids/3: as integer! "2.16.840.1.113730.4.1"
		para/usage/usage/cUsageIdentifier: 1
		para/usage/usage/rgpszUsageIdentifier: ids
		flags: CERT_CHAIN_CACHE_END_CERT or
			   CERT_CHAIN_REVOCATION_CHECK_CACHE_ONLY or
			   CERT_CHAIN_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT
		cert-chain: 0
		unless CertGetCertificateChain null ctx null store para flags null :cert-chain [
			print "CertGetCertificateChain error: "
			print-line as int-ptr! GetLastError
			CertCloseStore store 0
			return false
		]
		flags: CERT_CHAIN_POLICY_IGNORE_ALL_REV_UNKNOWN_FLAGS
		user?: no
		chain: as CERT_CHAIN_CONTEXT cert-chain
		unless null? data/root-store [
			index: chain/cChain
			if index > 0 [
				last-chain: as CERT_SIMPLE_CHAIN chain/rgpChain/index
				elem-n: last-chain/cElement
				elem: last-chain/rgpElement
				loop elem-n [
					elem-p: as CERT_CHAIN_ELEMENT elem/1
					if find-ctx? data/root-store elem-p/pCertContext [
						user?: yes
					]
					elem: elem + 1
				]
			]
		]
		if all [not-sys not user?] [
			CertCloseStore store 0
			return false
		]
		if user? [
			flags: flags or CERT_CHAIN_POLICY_ALLOW_UNKNOWN_CA_FLAG
		]
		set-memory as byte-ptr! extra_para null-byte size? HTTPSPolicyCallbackData
		extra_para/cbSize: size? HTTPSPolicyCallbackData
		extra_para/dwAuthType: 2		;-- AUTHTYPE_SERVER
		domain: as red-string! block/select-word extra word/load "domain" no
		if TYPE_OF(domain) = TYPE_STRING [
			extra_para/pwszServerName: as byte-ptr! unicode/to-utf16 domain
		]
		policy/cbSize: size? CERT_CHAIN_POLICY_PARA
		policy/flags: flags
		policy/extra: as byte-ptr! extra_para
		set-memory as byte-ptr! status null-byte size? CERT_CHAIN_POLICY_STATUS
		status/cbSize: size? CERT_CHAIN_POLICY_STATUS

		unless CertVerifyCertificateChainPolicy as int-ptr! CERT_CHAIN_POLICY_SSL chain policy status [
			print "CertVerifyCertificateChainPolicy error: "
			print-line as int-ptr! GetLastError
			CertCloseStore store 0
			return false
		]

		if status/dwError <> 0 [
			print "CertVerifyCertificateChainPolicy failed: "
			print-line as int-ptr! status/dwError
			CertCloseStore store 0
			return false
		]

		CertCloseStore store 0
		true
	]

	negotiate: func [
		data		[tls-data!]
		return:		[integer!]		;-- 0: continue, 1: success, -1: error
		/local
			_indesc		[SecBufferDesc! value]
			indesc		[SecBufferDesc!]
			outdesc		[SecBufferDesc! value]
			outbuf-1	[SecBuffer!]
			outbuf-2	[SecBuffer!]
			inbuf-1		[SecBuffer!]
			inbuf-2		[SecBuffer!]
			extra-buf	[SecBuffer!]
			expiry		[tagFILETIME value]
			ret			[integer!]
			attr		[integer!]
			buflen		[integer!]
			sec-handle	[SecHandle!]
			sec-handle2	[SecHandle!]
			pbuffer		[byte-ptr!]
			outbuffer	[byte-ptr!]
			s			[series!]
			client?		[logic!]
			state		[integer!]
			credential	[SecHandle! value]
			cert		[CERT_CONTEXT]
			ctx-size	[SecPkgContext_StreamSizes value]
			finished	[integer!]
	][
		finished: 1
		state: data/state
		client?: state and IO_STATE_CLIENT <> 0

		;-- allocate 2 SecBuffer! on stack for buffer
		inbuf-1: as SecBuffer! system/stack/allocate (size? SecBuffer!) >> 1
		inbuf-2: inbuf-1 + 1
		outbuf-1: as SecBuffer! system/stack/allocate (size? SecBuffer!) >> 1
		outbuf-2: outbuf-1 + 1

		buflen: data/buf-len

		if null? data/security [
			create data
			create-credentials data client?
		]

		s: as series! data/send-buf/value
		pbuffer: as byte-ptr! s/offset
		outbuffer: pbuffer + (MAX_SSL_MSG_LENGTH * 2)

		switch data/event [
			IO_EVT_READ [buflen: buflen + data/transferred]
			IO_EVT_ACCEPT [
				state: state or IO_STATE_READING
			]
			default [0]
		]

		if state and IO_STATE_READING <> 0 [
			data/state: state and (not IO_STATE_READING)
			socket/recv
						as-integer data/device
						pbuffer + buflen
						MAX_SSL_MSG_LENGTH * 2 - buflen
						as iocp-data! data 
			return 0
		]

		indesc: as SecBufferDesc! :_indesc

		forever [
			;-- setup input buffers
			inbuf-1/BufferType: 2		;-- SECBUFFER_TOKEN
			inbuf-1/cbBuffer: buflen
			inbuf-1/pvBuffer: pbuffer
			inbuf-2/BufferType: 0		;-- SECBUFFER_EMPTY
			inbuf-2/cbBuffer: 0
			inbuf-2/pvBuffer: null
			indesc/ulVersion: 0
			indesc/cBuffers: 2
			indesc/pBuffers: inbuf-1

			;-- setup output buffers
			outbuf-1/BufferType: 2
			outbuf-1/cbBuffer: MAX_SSL_MSG_LENGTH * 2
			outbuf-1/pvBuffer: outbuffer
			outdesc/ulVersion: 0
			outdesc/cBuffers: 1
			outdesc/pBuffers: outbuf-1

			either null? data/security [
				sec-handle: null
				sec-handle2: as SecHandle! :data/security
				if client? [
					indesc: null
					inbuf-1/pvBuffer: null
				]
				io/pin-memory data/send-buf
			][
				sec-handle: as SecHandle! :data/security
				sec-handle2: null
			]

			attr: 0
			either client? [
				ret: platform/SSPI/InitializeSecurityContextW
					data/credential
					sec-handle
					get-domain data
					sspi-flags-client
					0
					10h			;-- SECURITY_NATIVE_DREP
					indesc
					0
					sec-handle2
					outdesc
					:attr
					:expiry
			][
				outbuf-2/BufferType: 0		;-- SECBUFFER_EMPTY
				outbuf-2/cbBuffer: 0
				outbuf-2/pvBuffer: null
				outdesc/cBuffers: 2
				ret: platform/SSPI/AcceptSecurityContext
					data/credential
					sec-handle
					indesc
					sspi-flags-server
					0
					sec-handle2
					outdesc
					:attr
					:expiry
			]

			switch ret [
				SEC_OK
				SEC_I_CONTINUE_NEEDED [
					;-- this error means that information we provided in contextData is not enough to generate SSL token.
					;-- We'll ask other party for more information by sending our unfinished "token",
					;-- and then we will start all over - from the response that we'll get from the other party.
					extra-buf: inbuf-2
					if all [
						not client?
						inbuf-2/BufferType <> 5		;-- SECBUFFER_EXTRA
					][
						extra-buf: outbuf-2
					]
					if all [
						outbuf-1/cbBuffer > 0
						outbuf-1/pvBuffer <> null
					][
						io/pin-memory data/send-buf
						data/state: state or IO_STATE_READING
						if ret = SEC_OK [
							finished: 0
							data/state: state or IO_STATE_WRITING
						]
						if 0 > socket/send
							as-integer data/device
							outbuf-1/pvBuffer
							outbuf-1/cbBuffer
							as iocp-data! data [
								probe "handshake send error"
								release-context data
								;TBD post close event to port
							]
					]

					if ret = SEC_OK [
						if client? [
							if null? data/root-store [
								store-roots data
							]
							unless validate? data sec-handle [return 0]
						]
						data/state: state or IO_STATE_TLS_DONE
						platform/SSPI/QueryContextAttributesW
							sec-handle
							4			;-- SECPKG_ATTR_STREAM_SIZES
							as byte-ptr! :ctx-size
						data/ctx-max-msg: ctx-size/cbMaximumMessage
						data/ctx-header: ctx-size/cbHeader
						data/ctx-trailer: ctx-size/cbTrailer

						data/buf-len: 0
						either client? [extra-buf: inbuf-2][extra-buf: outbuf-2]
						if extra-buf/BufferType = 5 [
							0
						]

						either client? [
							data/event: IO_EVT_CONNECT
						][
							data/event: IO_EVT_ACCEPT
						]
						return finished
					]

					either all [
						extra-buf/BufferType = 5
						extra-buf/cbBuffer > 0
					][
						;-- part of data is digested and is not needed to be supplied again.
						;-- So we shift our leftover into the beginning
						move-memory pbuffer pbuffer + (buflen - extra-buf/cbBuffer) extra-buf/cbBuffer
						buflen: extra-buf/cbBuffer
						data/buf-len: buflen
						continue		;-- start all over again
					][
						data/buf-len: 0
						return 0
					]
				]
				SEC_E_INCOMPLETE_MESSAGE [
					socket/recv
						as-integer data/device
						pbuffer + buflen
						MAX_SSL_MSG_LENGTH * 2 - buflen
						as iocp-data! data
					data/state: state and (not IO_STATE_READING)
					return 0
				]
				SEC_E_INCOMPLETE_CREDENTIALS [
					;cert-client: get-credential data yes
					;if null? cert-client [return 0]
					create-credentials data client?
				]
				default [
					probe ["InitializeSecurityContext Error " ret]
					return -1
				]
			]
		]
		0
	]

	encode: func [
		output	[byte-ptr!]
		buffer	[byte-ptr!]
		length	[integer!]
		data	[tls-data!]
		return: [integer!]
		/local
			buffer4	[secbuffer! value]
			buffer3	[secbuffer! value]
			buffer2	[SecBuffer! value]
			buffer1	[SecBuffer! value]
			sbin	[SecBufferDesc! value]
			status	[integer!]
	][
		copy-memory output + data/ctx-header buffer length

		buffer1/BufferType: 7		;-- SECBUFFER_STREAM_HEADER
		buffer1/cbBuffer: data/ctx-header
		buffer1/pvBuffer: output

		output: output + data/ctx-header
		buffer2/BufferType: 1		;-- SECBUFFER_DATA
		buffer2/cbBuffer: length
		buffer2/pvBuffer: output

		buffer3/BufferType: 6		;-- SECBUFFER_STREAM_TRAILER
		buffer3/cbBuffer: data/ctx-trailer
		buffer3/pvBuffer: output + length

		buffer4/BufferType: 0		;-- SECBUFFER_EMPTY
		buffer4/cbBuffer: 0
		buffer4/pvBuffer: null

		sbin/ulVersion: 0
		sbin/pBuffers: :buffer1
		sbin/cBuffers: 4

		status: platform/SSPI/EncryptMessage
			as SecHandle! :data/security
			0
			sbin
			0
		if status <> 0 [return 0]

		buffer1/cbBuffer + buffer2/cbBuffer + buffer3/cbBuffer
	]

	send-data: func [
		data		[tls-data!]
		return:		[logic!]		;-- false if sent all data
		/local
			len	sz	[integer!]
			sent-sz [integer!]
			ser		[red-series! value]
			p		[byte-ptr!]
	][
		ser/head: data/head
		ser/node: data/send-buf
		len: _series/get-length ser no
		sent-sz: data/sent-sz

		if sent-sz = len [return false]

		sz: len - sent-sz
		if sz > data/ctx-max-msg [sz: data/ctx-max-msg]
		data/sent-sz: sent-sz + sz

		p: binary/rs-head as red-binary! ser
		-1 <> send as-integer data/device p + sent-sz sz data
	]

	send: func [
		sock		[integer!]
		buffer		[byte-ptr!]
		length		[integer!]
		data		[tls-data!]
		return:		[integer!]
		/local
			wsbuf	[WSABUF! value]
			err		[integer!]
			outbuf	[byte-ptr!]
	][
		#if debug? = yes [if verbose > 0 [print-line "tls/send"]]

		outbuf: data/tls-buf
		length: encode outbuf buffer length data
		wsbuf/len: length
		wsbuf/buf: outbuf
		data/event: IO_EVT_WRITE

		unless zero? WSASend sock :wsbuf 1 null 0 as OVERLAPPED! data null [	;-- error
			err: GetLastError
			either ERROR_IO_PENDING = err [return ERROR_IO_PENDING][return -1]
		]
		0
	]

	recv: func [
		sock		[integer!]
		buffer		[byte-ptr!]
		length		[integer!]
		data		[tls-data!]
		return:		[integer!]
		/local
			extra	[integer!]
	][
		extra: data/buf-len
		if extra > 0 [copy-memory buffer data/tls-extra extra]
		socket/recv sock buffer + extra length - extra as iocp-data! data
	]

	decode: func [
		data	[tls-data!]
		return: [logic!]
		/local
			bin	[red-binary!]
			s	[series!]
			len [integer!]
			buffer4	[secbuffer! value]
			buffer3	[secbuffer! value]
			buffer2	[SecBuffer! value]
			buffer1	[SecBuffer! value]
			sbin	[SecBufferDesc! value]
			len2	[integer!]
			status	[integer!]
			buf		[SecBuffer!]
			i		[integer!]
			pbuffer	[byte-ptr!]
			src		[byte-ptr!]
			src-len [integer!]
			extra?  [logic!]
	][
		if zero? data/transferred [	;-- peer socket was closed
			data/event: IO_EVT_CLOSE
			return yes
		]

		extra?: no
		len: 0
		status: 0
		bin: as red-binary! (object/get-values as red-object! :data/port) + port/field-data
		s: GET_BUFFER(bin)
		pbuffer: as byte-ptr! s/offset
		src: pbuffer
		src-len: data/transferred + data/buf-len

		until [
			buffer1/BufferType: 1		;-- SECBUFFER_DATA
			buffer1/cbBuffer: src-len
			buffer1/pvBuffer: src
	 
			buffer2/BufferType: 0
			buffer3/BufferType: 0
			buffer4/BufferType: 0		;-- SECBUFFER_EMPTY

			sbin/ulVersion: 0
			sbin/pBuffers: :buffer1
			sbin/cBuffers: 4

			status: platform/SSPI/DecryptMessage
				as SecHandle! :data/security
				sbin
				0
				null

			switch status [
				0	[		;-- Wow! success!
					buf: :buffer1
					data/buf-len: 0
					loop 3 [
						buf: buf + 1
						if buf/BufferType = 1 [
							move-memory pbuffer + len buf/pvBuffer buf/cbBuffer
							len: len + buf/cbBuffer
						]
						if buf/BufferType = 5 [	;-- some leftover, save it
							extra?: yes
							src: buf/pvBuffer
							src-len: buf/cbBuffer

							if data/extra-sz < src-len [
								if data/tls-extra <> null [mimalloc/free data/tls-extra]
								data/tls-extra: mimalloc/malloc src-len
								data/extra-sz: src-len
							]
							copy-memory data/tls-extra src src-len
							data/buf-len: src-len
						]
					]
				]
				SEC_E_INCOMPLETE_MESSAGE [		;-- needs more data
					if extra? [break]

					len2: data/buf-len + data/transferred
					data/buf-len: len2
					socket/recv
						as-integer data/device
						pbuffer + len2
						s/size - len2
						as iocp-data! data
					return false
				]
				00090317h [		;-- SEC_I_CONTEXT_EXPIRED
					data/event: IO_EVT_CLOSE
					len: 0
					break
				]
				default [probe ["error in tls/decode: " as int-ptr! status]]
			]
			extra? = no
		]
		data/transferred: len
		true
	]

	free-handle: func [
		td		[tls-data!]
	][
		;TBD free TLS resource
		release-context td
		socket/close as-integer td/device
		td/device: IO_INVALID_DEVICE
		if td/tls-buf <> null [mimalloc/free td/tls-buf]
		if td/tls-extra <> null [mimalloc/free td/tls-extra]
	]
]