(function (global) {
  'use strict';

  var COMPONENTS = {
    5120: { bytes: 1, getter: 'getInt8' },
    5121: { bytes: 1, getter: 'getUint8' },
    5122: { bytes: 2, getter: 'getInt16' },
    5123: { bytes: 2, getter: 'getUint16' },
    5125: { bytes: 4, getter: 'getUint32' },
    5126: { bytes: 4, getter: 'getFloat32' }
  };
  var TYPE_LENGTH = { SCALAR: 1, VEC2: 2, VEC3: 3, VEC4: 4, MAT2: 4, MAT3: 9, MAT4: 16 };
  var IDENTITY = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
  // 3D Tiles renders glTF in a Z-up world. glTF defaults to Y-up, so Cesium
  // applies this conversion after the glTF scene graph and before tile.transform.
  var Y_UP_TO_Z_UP = [1, 0, 0, 0, 0, 0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1];
  var X_UP_TO_Z_UP = [0, 0, 1, 0, 0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 0, 1];

  function upAxisTransform(axis) {
    var normalized = String(axis || 'Y').toUpperCase();
    if (normalized === 'Z') return IDENTITY;
    if (normalized === 'X') return X_UP_TO_Z_UP;
    return Y_UP_TO_Z_UP;
  }

  function parseGlb(arrayBuffer) {
    var view = new DataView(arrayBuffer);
    var offset = 12;
    var json;
    var binary;
    if (view.byteLength < 20 || view.getUint32(0, true) !== 0x46546c67) throw new Error('Invalid GLB magic');
    if (view.getUint32(4, true) !== 2) throw new Error('Only GLB 2.0 is supported');
    while (offset + 8 <= view.byteLength) {
      var length = view.getUint32(offset, true);
      var type = view.getUint32(offset + 4, true);
      var start = offset + 8;
      if (type === 0x4e4f534a) {
        json = JSON.parse(new TextDecoder().decode(new Uint8Array(arrayBuffer, start, length)).replace(/[\u0000\s]+$/, ''));
      } else if (type === 0x004e4942) {
        binary = new Uint8Array(arrayBuffer, start, length);
      }
      offset = start + length;
    }
    if (!json || !binary) throw new Error('GLB must contain JSON and BIN chunks');
    return { json: json, binary: binary };
  }

  function accessorValues(glb, accessorIndex) {
    var accessor = glb.json.accessors[accessorIndex];
    var bufferView = glb.json.bufferViews[accessor.bufferView];
    var component = COMPONENTS[accessor.componentType];
    var width = TYPE_LENGTH[accessor.type];
    var start = (bufferView.byteOffset || 0) + (accessor.byteOffset || 0);
    var stride = bufferView.byteStride || component.bytes * width;
    var view = new DataView(glb.binary.buffer, glb.binary.byteOffset, glb.binary.byteLength);
    var values = new Array(accessor.count * width);
    var i;
    var j;
    if (!component || !width) throw new Error('Unsupported glTF accessor type');
    for (i = 0; i < accessor.count; i += 1) {
      for (j = 0; j < width; j += 1) {
        values[i * width + j] = view[component.getter](start + i * stride + j * component.bytes, true);
      }
    }
    return values;
  }

  function bufferViewBytes(glb, index) {
    var view = glb.json.bufferViews[index];
    return new Uint8Array(glb.binary.buffer, glb.binary.byteOffset + (view.byteOffset || 0), view.byteLength);
  }

  function stringPropertyValues(glb, property, count) {
    var values = bufferViewBytes(glb, property.values);
    var offsets = bufferViewBytes(glb, property.stringOffsets);
    var offsetView = new DataView(offsets.buffer, offsets.byteOffset, offsets.byteLength);
    var offsetBytes = offsets.byteLength / (count + 1);
    var decoder = new TextDecoder();
    var result = [];
    var getter = offsetBytes === 8 ? 'getBigUint64' : offsetBytes === 2 ? 'getUint16' : offsetBytes === 1 ? 'getUint8' : 'getUint32';
    var i;
    for (i = 0; i < count; i += 1) {
      var start = Number(offsetView[getter](i * offsetBytes, true));
      var end = Number(offsetView[getter]((i + 1) * offsetBytes, true));
      result.push(decoder.decode(values.subarray(start, end)));
    }
    return result;
  }

  function propertyTableStrings(glb, tableIndex) {
    var metadata = glb.json.extensions && glb.json.extensions.EXT_structural_metadata;
    var table = metadata && metadata.propertyTables && metadata.propertyTables[tableIndex];
    var schemaClass = table && metadata.schema && metadata.schema.classes && metadata.schema.classes[table.class];
    var result = {};
    if (!table) throw new Error('GLB structural metadata property table is missing');
    Object.keys(table.properties || {}).forEach(function (name) {
      var definition = schemaClass && schemaClass.properties && schemaClass.properties[name];
      var property = table.properties[name];
      if ((definition && definition.type === 'STRING') || property.stringOffsets != null) {
        result[name] = stringPropertyValues(glb, property, table.count);
      }
    });
    return { count: table.count, values: result };
  }

  function findFeatureId(strings, identifiers) {
    var wanted = identifiers.map(String);
    var names = Object.keys(strings.values);
    var featureId;
    var nameIndex;
    for (featureId = 0; featureId < strings.count; featureId += 1) {
      for (nameIndex = 0; nameIndex < names.length; nameIndex += 1) {
        var value = strings.values[names[nameIndex]][featureId];
        if (wanted.indexOf(String(value)) !== -1) return { featureId: featureId, identifier: String(value) };
      }
    }
    return null;
  }

  function multiplyMatrices(left, right) {
    var output = new Array(16);
    var column;
    var row;
    var k;
    for (column = 0; column < 4; column += 1) {
      for (row = 0; row < 4; row += 1) {
        output[column * 4 + row] = 0;
        for (k = 0; k < 4; k += 1) output[column * 4 + row] += left[k * 4 + row] * right[column * 4 + k];
      }
    }
    return output;
  }

  function nodeMatrix(node) {
    if (node.matrix) return node.matrix;
    var translation = node.translation || [0, 0, 0];
    var rotation = node.rotation || [0, 0, 0, 1];
    var scale = node.scale || [1, 1, 1];
    var x = rotation[0]; var y = rotation[1]; var z = rotation[2]; var w = rotation[3];
    var xx = x * x; var xy = x * y; var xz = x * z; var xw = x * w;
    var yy = y * y; var yz = y * z; var yw = y * w; var zz = z * z; var zw = z * w;
    return [
      (1 - 2 * (yy + zz)) * scale[0], (2 * (xy + zw)) * scale[0], (2 * (xz - yw)) * scale[0], 0,
      (2 * (xy - zw)) * scale[1], (1 - 2 * (xx + zz)) * scale[1], (2 * (yz + xw)) * scale[1], 0,
      (2 * (xz + yw)) * scale[2], (2 * (yz - xw)) * scale[2], (1 - 2 * (xx + yy)) * scale[2], 0,
      translation[0], translation[1], translation[2], 1
    ];
  }

  function transformPoint(matrix, x, y, z, output) {
    output.push(
      matrix[0] * x + matrix[4] * y + matrix[8] * z + matrix[12],
      matrix[1] * x + matrix[5] * y + matrix[9] * z + matrix[13],
      matrix[2] * x + matrix[6] * y + matrix[10] * z + matrix[14]
    );
  }

  function readFeatureVertices(options) {
    var glb = parseGlb(options.arrayBuffer);
    var tileTransform = options.tileTransform || IDENTITY;
    var axisTransform = upAxisTransform(options.gltfUpAxis);
    var sceneIndex = glb.json.scene || 0;
    var roots = glb.json.scenes[sceneIndex].nodes || [];
    var resultPositions = [];
    var selectedIdentifier;
    var selectedFeatureId;

    function visit(nodeIndex, parentTransform) {
      var node = glb.json.nodes[nodeIndex];
      var modelTransform = multiplyMatrices(parentTransform, nodeMatrix(node));
      var worldTransform = multiplyMatrices(tileTransform, multiplyMatrices(axisTransform, modelTransform));
      if (node.mesh != null) {
        (glb.json.meshes[node.mesh].primitives || []).forEach(function (primitive) {
          var meshFeatures = primitive.extensions && primitive.extensions.EXT_mesh_features;
          var featureSet = meshFeatures && meshFeatures.featureIds && meshFeatures.featureIds[0];
          if (!featureSet || featureSet.attribute == null || featureSet.propertyTable == null) return;
          var strings = propertyTableStrings(glb, featureSet.propertyTable);
          var selected = findFeatureId(strings, options.identifiers || []);
          if (!selected) return;
          var positions = accessorValues(glb, primitive.attributes.POSITION);
          var featureIds = accessorValues(glb, primitive.attributes['_FEATURE_ID_' + featureSet.attribute]);
          var i;
          selectedIdentifier = selected.identifier;
          selectedFeatureId = selected.featureId;
          for (i = 0; i < featureIds.length; i += 1) {
            if (Math.round(featureIds[i]) === selected.featureId) {
              transformPoint(worldTransform, positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2], resultPositions);
            }
          }
        });
      }
      (node.children || []).forEach(function (child) { visit(child, modelTransform); });
    }

    roots.forEach(function (root) { visit(root, IDENTITY); });
    if (!resultPositions.length) throw new Error('Feature not found in GLB structural metadata');
    return {
      identifier: selectedIdentifier,
      featureId: selectedFeatureId,
      vertexCount: resultPositions.length / 3,
      positions: resultPositions
    };
  }

  function readFeatureMesh(options) {
    var glb = parseGlb(options.arrayBuffer);
    var tileTransform = options.tileTransform || IDENTITY;
    var axisTransform = upAxisTransform(options.gltfUpAxis);
    var sceneIndex = glb.json.scene || 0;
    var roots = glb.json.scenes[sceneIndex].nodes || [];
    var resultPositions = [];
    var resultIndices = [];
    var selectedIdentifier;
    var selectedFeatureId;

    function visit(nodeIndex, parentTransform) {
      var node = glb.json.nodes[nodeIndex];
      var modelTransform = multiplyMatrices(parentTransform, nodeMatrix(node));
      var worldTransform = multiplyMatrices(tileTransform, multiplyMatrices(axisTransform, modelTransform));
      if (node.mesh != null) {
        (glb.json.meshes[node.mesh].primitives || []).forEach(function (primitive) {
          var meshFeatures = primitive.extensions && primitive.extensions.EXT_mesh_features;
          var featureSet = meshFeatures && meshFeatures.featureIds && meshFeatures.featureIds[0];
          if (!featureSet || featureSet.attribute == null || featureSet.propertyTable == null) return;
          if (primitive.mode != null && primitive.mode !== 4) throw new Error('Only glTF TRIANGLES primitives are supported');
          var strings = propertyTableStrings(glb, featureSet.propertyTable);
          var selected = findFeatureId(strings, options.identifiers || []);
          if (!selected) return;
          var positions = accessorValues(glb, primitive.attributes.POSITION);
          var featureIds = accessorValues(glb, primitive.attributes['_FEATURE_ID_' + featureSet.attribute]);
          var sourceIndices = primitive.indices == null
            ? featureIds.map(function (_, index) { return index; })
            : accessorValues(glb, primitive.indices);
          var remap = Object.create(null);

          function outputIndex(sourceIndex) {
            if (Object.prototype.hasOwnProperty.call(remap, sourceIndex)) return remap[sourceIndex];
            var output = resultPositions.length / 3;
            transformPoint(
              worldTransform,
              positions[sourceIndex * 3],
              positions[sourceIndex * 3 + 1],
              positions[sourceIndex * 3 + 2],
              resultPositions
            );
            remap[sourceIndex] = output;
            return output;
          }

          selectedIdentifier = selected.identifier;
          selectedFeatureId = selected.featureId;
          for (var i = 0; i + 2 < sourceIndices.length; i += 3) {
            var a = sourceIndices[i]; var b = sourceIndices[i + 1]; var c = sourceIndices[i + 2];
            if (Math.round(featureIds[a]) !== selected.featureId ||
                Math.round(featureIds[b]) !== selected.featureId ||
                Math.round(featureIds[c]) !== selected.featureId) continue;
            resultIndices.push(outputIndex(a), outputIndex(b), outputIndex(c));
          }
        });
      }
      (node.children || []).forEach(function (child) { visit(child, modelTransform); });
    }

    roots.forEach(function (root) { visit(root, IDENTITY); });
    if (!resultIndices.length) throw new Error('Feature mesh not found in GLB structural metadata');
    return {
      identifier: selectedIdentifier,
      featureId: selectedFeatureId,
      vertexCount: resultPositions.length / 3,
      triangleCount: resultIndices.length / 3,
      positions: resultPositions,
      indices: resultIndices
    };
  }

  global.HuaguoshanGlbFeatureGeometry = {
    readFeatureVertices: readFeatureVertices,
    readFeatureMesh: readFeatureMesh
  };
})(typeof window !== 'undefined' ? window : globalThis);
