import 'package:gql/ast.dart';

class Fragment$MediaFileFragment {
  Fragment$MediaFileFragment({
    required this.id,
    this.resolution,
    this.codec,
    this.audioCodec,
    this.hdrFormat,
    this.size,
    this.bitrate,
    this.directPlaySupported,
    this.streamUrl,
    this.directPlayUrl,
    this.$__typename = 'MediaFile',
  });

  factory Fragment$MediaFileFragment.fromJson(Map<String, dynamic> json) {
    final l$id = json['id'];
    final l$resolution = json['resolution'];
    final l$codec = json['codec'];
    final l$audioCodec = json['audioCodec'];
    final l$hdrFormat = json['hdrFormat'];
    final l$size = json['size'];
    final l$bitrate = json['bitrate'];
    final l$directPlaySupported = json['directPlaySupported'];
    final l$streamUrl = json['streamUrl'];
    final l$directPlayUrl = json['directPlayUrl'];
    final l$$__typename = json['__typename'];
    return Fragment$MediaFileFragment(
      id: (l$id as String),
      resolution: (l$resolution as String?),
      codec: (l$codec as String?),
      audioCodec: (l$audioCodec as String?),
      hdrFormat: (l$hdrFormat as String?),
      size: (l$size as int?),
      bitrate: (l$bitrate as int?),
      directPlaySupported: (l$directPlaySupported as bool?),
      streamUrl: (l$streamUrl as String?),
      directPlayUrl: (l$directPlayUrl as String?),
      $__typename: (l$$__typename as String),
    );
  }

  final String id;

  final String? resolution;

  final String? codec;

  final String? audioCodec;

  final String? hdrFormat;

  final int? size;

  final int? bitrate;

  final bool? directPlaySupported;

  final String? streamUrl;

  final String? directPlayUrl;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$id = id;
    _resultData['id'] = l$id;
    final l$resolution = resolution;
    _resultData['resolution'] = l$resolution;
    final l$codec = codec;
    _resultData['codec'] = l$codec;
    final l$audioCodec = audioCodec;
    _resultData['audioCodec'] = l$audioCodec;
    final l$hdrFormat = hdrFormat;
    _resultData['hdrFormat'] = l$hdrFormat;
    final l$size = size;
    _resultData['size'] = l$size;
    final l$bitrate = bitrate;
    _resultData['bitrate'] = l$bitrate;
    final l$directPlaySupported = directPlaySupported;
    _resultData['directPlaySupported'] = l$directPlaySupported;
    final l$streamUrl = streamUrl;
    _resultData['streamUrl'] = l$streamUrl;
    final l$directPlayUrl = directPlayUrl;
    _resultData['directPlayUrl'] = l$directPlayUrl;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$id = id;
    final l$resolution = resolution;
    final l$codec = codec;
    final l$audioCodec = audioCodec;
    final l$hdrFormat = hdrFormat;
    final l$size = size;
    final l$bitrate = bitrate;
    final l$directPlaySupported = directPlaySupported;
    final l$streamUrl = streamUrl;
    final l$directPlayUrl = directPlayUrl;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$id,
      l$resolution,
      l$codec,
      l$audioCodec,
      l$hdrFormat,
      l$size,
      l$bitrate,
      l$directPlaySupported,
      l$streamUrl,
      l$directPlayUrl,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Fragment$MediaFileFragment ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$id = id;
    final lOther$id = other.id;
    if (l$id != lOther$id) {
      return false;
    }
    final l$resolution = resolution;
    final lOther$resolution = other.resolution;
    if (l$resolution != lOther$resolution) {
      return false;
    }
    final l$codec = codec;
    final lOther$codec = other.codec;
    if (l$codec != lOther$codec) {
      return false;
    }
    final l$audioCodec = audioCodec;
    final lOther$audioCodec = other.audioCodec;
    if (l$audioCodec != lOther$audioCodec) {
      return false;
    }
    final l$hdrFormat = hdrFormat;
    final lOther$hdrFormat = other.hdrFormat;
    if (l$hdrFormat != lOther$hdrFormat) {
      return false;
    }
    final l$size = size;
    final lOther$size = other.size;
    if (l$size != lOther$size) {
      return false;
    }
    final l$bitrate = bitrate;
    final lOther$bitrate = other.bitrate;
    if (l$bitrate != lOther$bitrate) {
      return false;
    }
    final l$directPlaySupported = directPlaySupported;
    final lOther$directPlaySupported = other.directPlaySupported;
    if (l$directPlaySupported != lOther$directPlaySupported) {
      return false;
    }
    final l$streamUrl = streamUrl;
    final lOther$streamUrl = other.streamUrl;
    if (l$streamUrl != lOther$streamUrl) {
      return false;
    }
    final l$directPlayUrl = directPlayUrl;
    final lOther$directPlayUrl = other.directPlayUrl;
    if (l$directPlayUrl != lOther$directPlayUrl) {
      return false;
    }
    final l$$__typename = $__typename;
    final lOther$$__typename = other.$__typename;
    if (l$$__typename != lOther$$__typename) {
      return false;
    }
    return true;
  }
}

extension UtilityExtension$Fragment$MediaFileFragment
    on Fragment$MediaFileFragment {
  CopyWith$Fragment$MediaFileFragment<Fragment$MediaFileFragment>
  get copyWith => CopyWith$Fragment$MediaFileFragment(this, (i) => i);
}

abstract class CopyWith$Fragment$MediaFileFragment<TRes> {
  factory CopyWith$Fragment$MediaFileFragment(
    Fragment$MediaFileFragment instance,
    TRes Function(Fragment$MediaFileFragment) then,
  ) = _CopyWithImpl$Fragment$MediaFileFragment;

  factory CopyWith$Fragment$MediaFileFragment.stub(TRes res) =
      _CopyWithStubImpl$Fragment$MediaFileFragment;

  TRes call({
    String? id,
    String? resolution,
    String? codec,
    String? audioCodec,
    String? hdrFormat,
    int? size,
    int? bitrate,
    bool? directPlaySupported,
    String? streamUrl,
    String? directPlayUrl,
    String? $__typename,
  });
}

class _CopyWithImpl$Fragment$MediaFileFragment<TRes>
    implements CopyWith$Fragment$MediaFileFragment<TRes> {
  _CopyWithImpl$Fragment$MediaFileFragment(this._instance, this._then);

  final Fragment$MediaFileFragment _instance;

  final TRes Function(Fragment$MediaFileFragment) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? id = _undefined,
    Object? resolution = _undefined,
    Object? codec = _undefined,
    Object? audioCodec = _undefined,
    Object? hdrFormat = _undefined,
    Object? size = _undefined,
    Object? bitrate = _undefined,
    Object? directPlaySupported = _undefined,
    Object? streamUrl = _undefined,
    Object? directPlayUrl = _undefined,
    Object? $__typename = _undefined,
  }) => _then(
    Fragment$MediaFileFragment(
      id: id == _undefined || id == null ? _instance.id : (id as String),
      resolution: resolution == _undefined
          ? _instance.resolution
          : (resolution as String?),
      codec: codec == _undefined ? _instance.codec : (codec as String?),
      audioCodec: audioCodec == _undefined
          ? _instance.audioCodec
          : (audioCodec as String?),
      hdrFormat: hdrFormat == _undefined
          ? _instance.hdrFormat
          : (hdrFormat as String?),
      size: size == _undefined ? _instance.size : (size as int?),
      bitrate: bitrate == _undefined ? _instance.bitrate : (bitrate as int?),
      directPlaySupported: directPlaySupported == _undefined
          ? _instance.directPlaySupported
          : (directPlaySupported as bool?),
      streamUrl: streamUrl == _undefined
          ? _instance.streamUrl
          : (streamUrl as String?),
      directPlayUrl: directPlayUrl == _undefined
          ? _instance.directPlayUrl
          : (directPlayUrl as String?),
      $__typename: $__typename == _undefined || $__typename == null
          ? _instance.$__typename
          : ($__typename as String),
    ),
  );
}

class _CopyWithStubImpl$Fragment$MediaFileFragment<TRes>
    implements CopyWith$Fragment$MediaFileFragment<TRes> {
  _CopyWithStubImpl$Fragment$MediaFileFragment(this._res);

  TRes _res;

  call({
    String? id,
    String? resolution,
    String? codec,
    String? audioCodec,
    String? hdrFormat,
    int? size,
    int? bitrate,
    bool? directPlaySupported,
    String? streamUrl,
    String? directPlayUrl,
    String? $__typename,
  }) => _res;
}

const fragmentDefinitionMediaFileFragment = FragmentDefinitionNode(
  name: NameNode(value: 'MediaFileFragment'),
  typeCondition: TypeConditionNode(
    on: NamedTypeNode(name: NameNode(value: 'MediaFile'), isNonNull: false),
  ),
  directives: [],
  selectionSet: SelectionSetNode(
    selections: [
      FieldNode(
        name: NameNode(value: 'id'),
        alias: null,
        arguments: [],
        directives: [],
        selectionSet: null,
      ),
      FieldNode(
        name: NameNode(value: 'resolution'),
        alias: null,
        arguments: [],
        directives: [],
        selectionSet: null,
      ),
      FieldNode(
        name: NameNode(value: 'codec'),
        alias: null,
        arguments: [],
        directives: [],
        selectionSet: null,
      ),
      FieldNode(
        name: NameNode(value: 'audioCodec'),
        alias: null,
        arguments: [],
        directives: [],
        selectionSet: null,
      ),
      FieldNode(
        name: NameNode(value: 'hdrFormat'),
        alias: null,
        arguments: [],
        directives: [],
        selectionSet: null,
      ),
      FieldNode(
        name: NameNode(value: 'size'),
        alias: null,
        arguments: [],
        directives: [],
        selectionSet: null,
      ),
      FieldNode(
        name: NameNode(value: 'bitrate'),
        alias: null,
        arguments: [],
        directives: [],
        selectionSet: null,
      ),
      FieldNode(
        name: NameNode(value: 'directPlaySupported'),
        alias: null,
        arguments: [],
        directives: [],
        selectionSet: null,
      ),
      FieldNode(
        name: NameNode(value: 'streamUrl'),
        alias: null,
        arguments: [],
        directives: [],
        selectionSet: null,
      ),
      FieldNode(
        name: NameNode(value: 'directPlayUrl'),
        alias: null,
        arguments: [],
        directives: [],
        selectionSet: null,
      ),
      FieldNode(
        name: NameNode(value: '__typename'),
        alias: null,
        arguments: [],
        directives: [],
        selectionSet: null,
      ),
    ],
  ),
);
const documentNodeFragmentMediaFileFragment = DocumentNode(
  definitions: [fragmentDefinitionMediaFileFragment],
);
