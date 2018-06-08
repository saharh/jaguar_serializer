library jaguar_serializer.generator.helpers;

import 'package:analyzer/analyzer.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:source_gen/source_gen.dart';
import 'package:jaguar_serializer/jaguar_serializer.dart';

import 'package:jaguar_serializer_cli/src/info/info.dart';
import 'package:jaguar_serializer_cli/src/info/info.dart' as $info;
import 'package:jaguar_serializer_cli/src/utils/string.dart';
import 'package:jaguar_serializer_cli/src/utils/type_checkers.dart';
import 'package:jaguar_serializer_cli/src/utils/exceptions.dart';

/// Instantiates [GenSerializer] from [DartObject]
class AnnotationParser {
  final ConstantReader obj;

  final ClassElement element;

  /// Model type
  DartType modelType;

  ClassElement modelClass;

  /// Should fields be included by default
  bool includeByDefault;

  final Map<String, PropertyAccessorElement> getters =
      <String, PropertyAccessorElement>{};

  final Map<String, PropertyAccessorElement> setters =
      <String, PropertyAccessorElement>{};

  final Map<String, $info.Field> fields = <String, $info.Field>{};

  Map<InterfaceType, ClassElement> providers = {};

  bool globalNullable;

  AnnotationParser(this.element, this.obj);

  SerializerInfo parse() {
    globalNullable = obj.peek('nullableFields').boolValue;
    includeByDefault = obj.peek('includeByDefault').boolValue;

    _parseSerializers();
    _parseModelType();
    _parseIgnore();
    _parseFields();
    _parseFieldFormatters();

    for ($info.Field f in fields.values) {
      if (f.dontEncode && f.dontDecode) continue;
      if (f.dontEncode && f.dontDecode) continue;
      f.typeInfo = _expandTypeInfo(f.type, f.processor);
    }

    // TODO _makeCtor(modelType.element as ClassElement, ret.model);
    return new SerializerInfo(element.name, modelClass.displayName, fields);
  }

  /// Parses [modelType] of the Serializer
  void _parseModelType() {
    if (!isSerializer.isSuperTypeOf(element.type)) {
      throw new JCException('Serializers must be extended from `Serializer`!');
    }

    InterfaceType i = element.allSupertypes
        .firstWhere((InterfaceType i) => isSerializer.isExactly(i.element));
    modelType = i.typeArguments.first;
    if (modelType.isDynamic) throw new JCException('Model cannot be dynamic!');
    modelClass = modelType.element as ClassElement;

    bool isNotStaticOrPrivate(PropertyAccessorElement e) =>
        !e.isStatic && !e.isPrivate;

    final accessors = <PropertyAccessorElement>[];
    accessors.addAll(modelClass.accessors.where(isNotStaticOrPrivate));
    for (InterfaceType i in modelClass.allSupertypes) {
      accessors.addAll(i.accessors.where(isNotStaticOrPrivate));
    }

    for (PropertyAccessorElement field in accessors) {
      String name = field.displayName;
      if (name == 'runtimeType') continue;
      if (name == 'hashCode') continue;
      if (fields.containsKey(name)) continue;

      PropertyAccessorElement other;

      InterfaceType type;
      bool dontEncode = false;
      bool dontDecode = false;

      if (field.isGetter) {
        getters[name] = field;
        type = field.returnType as InterfaceType;
        other = accessors.firstWhere((p) => p.displayName == name && p.isSetter,
            orElse: () => null);
        if (other != null)
          setters[name] = other;
        else
          dontDecode = true;
      } else {
        setters[name] = field;
        type = field.type.parameters.first.type as InterfaceType;

        other = accessors.firstWhere((p) => p.displayName == name && p.isGetter,
            orElse: () => null);
        if (other != null)
          getters[name] = other;
        else
          dontEncode = true;
      }

      DartObject annot = field.metadata
          .firstWhere(
              (ElementAnnotation a) =>
                  isProperty.isSuperOf(a.computeConstantValue().type.element),
              orElse: () => null)
          ?.constantValue;
      annot ??= other?.metadata
          ?.firstWhere(
              (ElementAnnotation a) =>
                  isProperty.isSuperOf(a.computeConstantValue().type.element),
              orElse: () => null)
          ?.constantValue;

      String encodeTo = name;
      String decodeFrom = name;
      bool nullable = globalNullable;
      String defaultValue;
      bool fromConstructor = false;
      FieldProcessorInfo processor;
      if (annot != null) {
        dontEncode =
            annot.getField('dontEncode').toBoolValue() ? true : dontEncode;
        dontDecode =
            annot.getField('dontDecode').toBoolValue() ? true : dontDecode;

        encodeTo = annot.getField('encodeTo')?.toStringValue() ?? encodeTo;
        decodeFrom =
            annot.getField('decodeFrom')?.toStringValue() ?? decodeFrom;

        nullable = annot.getField('isNullable').toBoolValue() ?? nullable;
        defaultValue = _parseFieldDefaultValue(annot.getField('defaultsTo'));
        fromConstructor = annot.getField('valueFromConstructor').toBoolValue();
        processor = _parseFieldProcessor(annot.getField('processor'));
      }

      if (includeByDefault || annot != null) {
        fields[name] = new $info.Field(
          name: name,
          dontEncode: dontEncode,
          dontDecode: dontDecode,
          type: type,
          encodeTo: encodeTo,
          decodeFrom: decodeFrom,
          processor: processor,
          provider: null, // TODO
          isNullable: nullable && defaultValue == null && !fromConstructor,
          defaultValue: defaultValue,
          fromConstructor: fromConstructor,
        );
      }
    }

    /* TODO
    modelClass.fields
        .where((f) => f.isFinal && !f.isStatic && !f.isPrivate)
        .forEach((FieldElement f) {
      mod.addFrom(new $info.Field(f.displayName, f.type as InterfaceType,
          isFinal: true));
    });
    */
  }

  void _parseIgnore() {
    for (DartObject ig in obj.peek('ignore').listValue) {
      String fieldName = _mapToString(ig);
      fields[fieldName] = new $info.Field(
          name: fieldName,
          dontEncode: true,
          dontDecode: true,
          type: null,
          encodeTo: null,
          decodeFrom: null,
          processor: null,
          provider: null,
          isNullable: null,
          defaultValue: null,
          fromConstructor: false);
    }
  }

  void _parseFieldFormatters() {
    /* TODO
    final format = obj.peek('fieldFormat')?.stringValue;
    fieldFormatter = (str) => str;
    if (format == FieldFormat.camelCase) {
      fieldFormatter = toCamelCase;
    } else if (format == FieldFormat.snakeCase) {
      fieldFormatter = toSnakeCase;
    } else if (format == FieldFormat.kebabCase) {
      fieldFormatter = toKebabCase;
    }
    */
  }

  void _parseSerializers() {
    final List<DartObject> list = obj.peek('serializers')?.listValue ?? [];
    list.map((DartObject obj) => obj.toTypeValue()).forEach((DartType t) {
      if (!isSerializer.isSuperTypeOf(t)) {
        throw new JCException('serializers must be sub-type of Serializer!');
      }

      final ClassElement v = t.element;
      final InterfaceType i = v.allSupertypes
          .where((InterfaceType i) => isSerializer.isExactly(i.element))
          .first;

      final DartType key = i.typeArguments[0];
      providers[key as InterfaceType] = v;
    });
  }

  /// Parses fields of the GenSerializer
  void _parseFields() {
    Map<DartObject, DartObject> map = obj.peek('fields').mapValue;
    for (DartObject dKey in map.keys)
      _processField(dKey.toStringValue(), map[dKey]);
  }

  void _processField(String key, DartObject dV) {
    FieldProcessorInfo processor =
        _parseFieldProcessor(dV.getField('processor'));
    // TODO verify if it is valid FieldProcessor type
    // TODO use default processor for [DateTime] and [Duration]
    bool isNullable =
        dV.getField('isNullable')?.toBoolValue() ?? globalNullable;
    String defVal = _parseFieldDefaultValue(dV.getField('defaultsTo'));
    bool valFromCon = dV.getField('valueFromConstructor').toBoolValue();

    fields[key] = new $info.Field(
      name: key,
      type: _getTypeOfField(key),
      dontEncode: dV.getField('dontEncode').toBoolValue(),
      dontDecode: dV.getField('dontDecode').toBoolValue(),
      encodeTo: _getStringField(dV, 'encodeTo') ?? key,
      decodeFrom: _getStringField(dV, 'decodeFrom') ?? key,
      processor: processor,
      provider: null, // TODO
      isNullable: isNullable && defVal == null && !valFromCon,
      defaultValue: defVal,
      fromConstructor: valFromCon,
    );
  }

  /* TODO
  void _makeCtor(ClassElement el, Model model) {
    ConstructorElement ctor = el.unnamedConstructor;
    if (ctor == null) {
      throw new JCException(
          "The class `${el.name}` has no default constructor.");
    }
    for (final arg in ctor.parameters) {
      final field = model.getFrom(arg.name);
      if (field?.isFinal == true) {
        if (arg.parameterKind == ParameterKind.NAMED) {
          model.ctorNamedArguments.add(arg);
        } else {
          model.ctorArguments.add(arg);
        }
      }
    }
  }
  */

  InterfaceType _getTypeOfField(String name) {
    return (getters[name]?.returnType ?? setters[name]?.parameters.first.type)
        as InterfaceType;
  }

  TypeInfo _expandTypeInfo(InterfaceType type, FieldProcessorInfo processor) {
    final TypeChecker typeChecker = new TypeChecker.fromStatic(type);
    if (processor != null &&
        typeChecker.isExactlyType(processor.deserialized)) {
      return new ProcessedTypeInfo(processor.instantiationString,
          processor.serializedStr, processor.deserializedStr);
    }

    if (isBuiltin(type)) {
      return new BuiltinTypeInfo(type.displayName);
    } else if (type is InterfaceType && isList.isExactlyType(type)) {
      final param = type.typeArguments.first as InterfaceType;
      return new ListTypeInfo(
          _expandTypeInfo(param, processor), param.displayName);
    } else if (type is InterfaceType && isMap.isExactlyType(type)) {
      final key = type.typeArguments.first as InterfaceType;
      final value = type.typeArguments[1] as InterfaceType;

      if (key.displayName != "String") {
        // TODO fix this
        throw new JCException(
            'Serializer only support "String" key for a Map!');
      }
      return new MapTypeInfo(_expandTypeInfo(key, processor), key.displayName,
          _expandTypeInfo(value, processor), value.displayName);
    } else if (type.isDynamic) {
      throw new JCException('Cannot serialize "dynamic" type!');
    } else if (type.isObject) {
      throw new JCException('Cannot serialize "Object" type!');
    }

    if (providers.containsKey(type)) {
      ClassElement ser = providers[type];
      return new SerializedTypeInfo(ser.displayName, type.displayName);
    }

    if (processor == null && isDateTime.isExactlyType(type)) {
      return new ProcessedTypeInfo(
          'dateTimeUtcProcessor', 'String', 'DateTime');
    }

    if (processor == null && isDuration.isExactlyType(type)) {
      return new ProcessedTypeInfo('durationProcessor', 'int', 'Duration');
    }

    throw new JCException('Cannot handle field!');
  }
}

bool _notNull(DartObject obj) => obj != null && obj.isNull == false;

String _getStringField(DartObject v, String name) =>
    v.getField(name)?.toStringValue();

String _mapToString(DartObject v) => v?.toStringValue();

String _parseFieldDefaultValue(DartObject dV) {
  if (!_notNull(dV)) return null;
  if (isString.isExactlyType(dV.type)) {
    return '"${dV.toStringValue()}"';
  } else if (isBool.isExactlyType(dV.type)) {
    return dV.toBoolValue().toString();
  } else if (isDouble.isExactlyType(dV.type)) {
    return dV.toDoubleValue().toString();
  } else if (isInt.isExactlyType(dV.type)) {
    return dV.toIntValue().toString();
  } else {
    // TODO more specific
    throw new JCException("Invalid value for `defaultsTo`");
  }
}

FieldProcessorInfo _parseFieldProcessor(DartObject processor) {
  if (!_notNull(processor)) return null;
  return new FieldProcessorInfo(processor.type);
}
