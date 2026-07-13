(function (global) {
  'use strict';

  function escapeHtml(value) {
    return String(value == null ? '' : value)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#039;');
  }

  function formatPropertyValue(value, uom) {
    if (value == null) return '--';
    var text = typeof value === 'object' ? JSON.stringify(value, null, 2) : String(value);
    return uom ? text + ' ' + uom : text;
  }

  function showPanel(panelSelector) {
    var panel = document.querySelector(panelSelector || '.feature-panel');
    if (panel) panel.hidden = false;
  }

  function hidePanel(panelSelector) {
    var panel = document.querySelector(panelSelector || '.feature-panel');
    if (panel) panel.hidden = true;
  }

  function featurePanel(contentSelector) {
    return document.querySelector(contentSelector || '#featureProperties');
  }

  function renderFeatureMessage(options, className, message) {
    showPanel(options && options.panelSelector);
    featurePanel(options && options.contentSelector).innerHTML = '<div class="' + className + '">' + escapeHtml(message) + '</div>';
  }

  function renderFeatureLoading(options, identifier, metadata) {
    var metadataHtml = '';
    showPanel(options && options.panelSelector);
    if (metadata && Object.keys(metadata).length) {
      metadataHtml = '<div class="tag-list">' + Object.keys(metadata).slice(0, 6).map(function (key) {
        return '<div class="tag-row"><b>' + escapeHtml(key) + '</b><code>' + escapeHtml(metadata[key]) + '</code></div>';
      }).join('') + '</div>';
    }

    featurePanel(options && options.contentSelector).innerHTML =
      '<div class="feature-loading">正在查询 CityDB 属性与 GGER 包围网格：<code>' + escapeHtml(identifier) + '</code>' + metadataHtml + '</div>';
  }

  function renderFeatureError(options, message) {
    renderFeatureMessage(options, 'feature-error', message);
  }

  function renderGridCard(gridData, extractGridCells) {
    var grid = gridData && gridData.grid;
    var cells = extractGridCells(gridData);
    var visibleCells = cells.slice(0, 10);
    var gridRows;

    if (!grid) {
      return '<div class="feature-grid-card"><h3>GGER Bounding Grid</h3>' +
        '<div class="feature-empty">该要素暂无 GGER 包围网格。</div></div>';
    }

    gridRows = visibleCells.map(function (cell) {
      return '<div class="feature-grid-cell"><b>' + escapeHtml(cell.code) + '</b>' +
        '<code>' + escapeHtml([
          cell.minLon.toFixed(8), cell.minLat.toFixed(8), cell.minHeight.toFixed(2),
          cell.maxLon.toFixed(8), cell.maxLat.toFixed(8), cell.maxHeight.toFixed(2)
        ].join(' · ')) + '</code></div>';
    }).join('');

    return '<div class="feature-grid-card">' +
      '<h3>GGER Bounding Grid</h3>' +
      '<div class="feature-meta">' +
        '<div class="feature-meta-row"><span>Detail</span><code>L' + escapeHtml(grid.detail_level) + '</code></div>' +
        '<div class="feature-meta-row"><span>Cells</span><code>' + escapeHtml(grid.cell_count || cells.length || 0) + '</code></div>' +
        '<div class="feature-meta-row"><span>Dimension</span><code>' + escapeHtml(grid.dimension) + 'D</code></div>' +
        '<div class="feature-meta-row"><span>Geometry</span><code>#' + escapeHtml(grid.geometry_id) + '</code></div>' +
      '</div>' +
      '<div class="feature-grid-actions">' +
        '<button type="button" data-action="zoomSelectedGrid">定位包围网格</button>' +
        '<button type="button" data-action="clearGridHighlight">清除高亮</button>' +
      '</div>' +
      '<div class="feature-grid-cells">' + (gridRows || '<div class="feature-empty">ST_WithBox 未返回可解析 bbox。</div>') + '</div>' +
      (cells.length > visibleCells.length ? '<div class="feature-empty">面板仅展示前 ' + visibleCells.length + ' / ' + cells.length + ' 个 cell；地图高亮已绘制全部 bbox。</div>' : '') +
    '</div>';
  }

  function renderFeatureProperties(options, data, sourceIdentifier, gridData, extractGridCells) {
    var feature;
    var properties;
    var title;
    var featureRows;
    var propertyHtml;
    showPanel(options && options.panelSelector);
    if (!data || !data.feature) {
      renderFeatureError(options, 'CityDB 未找到对应要素：' + sourceIdentifier);
      return;
    }

    feature = data.feature;
    properties = Array.isArray(data.properties) ? data.properties : [];
    title = feature.objectid || feature.identifier || ('Feature #' + feature.id);
    featureRows = [
      ['DB ID', feature.id],
      ['ObjectClass', feature.objectclass || feature.objectclass_id],
      ['Picked ID', sourceIdentifier],
      ['Identifier', feature.identifier],
      ['ObjectID', feature.objectid],
      ['Lineage', feature.lineage]
    ].filter(function (row) { return row[1] != null && row[1] !== ''; });

    propertyHtml = properties.map(function (property) {
      var children = Array.isArray(property.children) ? property.children : [];
      var value = formatPropertyValue(property.value, property.uom);
      var label = property.namespace_alias ? property.namespace_alias + ':' + property.name : property.name;
      var childHtml = '';
      if (children.length) {
        childHtml = '<div class="tag-list">' + children.map(function (child) {
          return '<div class="tag-row"><b>' + escapeHtml(child.name) + '</b><code>' +
            escapeHtml(formatPropertyValue(child.value, child.uom)) + '</code></div>';
        }).join('') + '</div>';
      }
      return '<div class="feature-property' + (children.length ? ' has-children' : '') + '">' +
        '<span>' + escapeHtml(label) + (property.datatype ? ' · ' + escapeHtml(property.datatype) : '') + '</span>' +
        (property.value == null ? '' : '<code>' + escapeHtml(value) + '</code>') +
        childHtml +
        '</div>';
    }).join('');

    featurePanel(options && options.contentSelector).innerHTML =
      '<div class="feature-card">' +
        '<div class="feature-title"><span>CityDB Feature</span><strong>' + escapeHtml(title) + '</strong></div>' +
        '<div class="feature-meta">' + featureRows.map(function (row) {
          return '<div class="feature-meta-row"><span>' + escapeHtml(row[0]) + '</span><code>' + escapeHtml(row[1]) + '</code></div>';
        }).join('') + '</div>' +
        renderGridCard(gridData, extractGridCells) +
        '<div class="feature-properties">' + (propertyHtml || '<div class="feature-empty">该要素没有属性记录。</div>') + '</div>' +
      '</div>';
  }

  function getPickedPropertyIds(picked) {
    if (!picked || typeof picked.getPropertyIds !== 'function') return [];
    try {
      var result = picked.getPropertyIds([]) || [];
      return Array.isArray(result) ? result : [];
    } catch (error) {
      console.warn('[Tianditu3D] Failed to read picked property ids:', error);
      return [];
    }
  }

  function getPickedProperty(picked, name) {
    if (!picked || typeof picked.getProperty !== 'function') return undefined;
    try {
      return picked.getProperty(name);
    } catch (error) {
      return undefined;
    }
  }

  function readPickedMetadata(picked) {
    var known = ['id', 'objectid', 'identifier', 'class', 'gen_derivedheight', 'gen_terrainelevation', 'gen_osmurl'];
    var ids = getPickedPropertyIds(picked);
    known.forEach(function (name) {
      if (ids.indexOf(name) === -1) ids.push(name);
    });

    return ids.reduce(function (metadata, name) {
      var value = getPickedProperty(picked, name);
      if (value != null && value !== '') metadata[name] = value;
      return metadata;
    }, {});
  }

  function metadataValue(metadata, names) {
    var index;
    for (index = 0; index < names.length; index += 1) {
      var name = names[index];
      if (metadata[name] != null && metadata[name] !== '') return metadata[name];
      var lower = name.toLowerCase();
      var match = Object.keys(metadata).find(function (key) { return key.toLowerCase() === lower; });
      if (match && metadata[match] != null && metadata[match] !== '') return metadata[match];
    }
    return null;
  }

  function getPickedIdentifiers(metadata) {
    var candidates = [
      metadataValue(metadata, ['id']),
      metadataValue(metadata, ['objectid']),
      metadataValue(metadata, ['identifier']),
      metadataValue(metadata, ['gen_osmurl', 'osmUrl', 'osmurl'])
    ];

    Object.keys(metadata).forEach(function (key) {
      var value = metadata[key];
      if (typeof value === 'string' && (/^osm:/.test(value) || /openstreetmap\.org/.test(value))) {
        candidates.push(value);
      }
    });

    return candidates.map(function (value) {
      return value == null ? '' : String(value).trim();
    }).filter(function (value, index, list) {
      return value && list.indexOf(value) === index;
    });
  }

  function isPickedCitydbFeature(picked, buildingsTileset) {
    var tilesets = Array.isArray(buildingsTileset) ? buildingsTileset : [buildingsTileset];
    var pickedTileset = picked && (picked.tileset || (picked.content && picked.content.tileset));
    if (!picked || typeof picked.getProperty !== 'function') return false;
    if (tilesets.filter(Boolean).length && pickedTileset && tilesets.indexOf(pickedTileset) === -1) return false;
    return true;
  }

  function flyToSelectedGridHighlight(CesiumRuntime, viewer, selectedGridBounds, log) {
    if (!viewer || !selectedGridBounds) {
      log('当前没有可定位的 GGER 包围网格。');
      return;
    }
    viewer.camera.flyTo({
      destination: CesiumRuntime.Rectangle.fromDegrees(
        selectedGridBounds.west,
        selectedGridBounds.south,
        selectedGridBounds.east,
        selectedGridBounds.north
      ),
      duration: 1.2
    });
    log('已定位到当前要素的 GGER 包围网格。');
  }

  function bindFeaturePicking(options) {
    var CesiumRuntime = options.CesiumRuntime;
    var viewer = options.viewer;
    var selectedRequestToken = null;
    var handler = new CesiumRuntime.ScreenSpaceEventHandler(viewer.scene.canvas);

    handler.setInputAction(function (movement) {
      var picked;
      var metadata;
      var identifiers;
      var requestToken;

      if (options.airspaceConstraintEditor && options.airspaceConstraintEditor.isDrawing()) {
        options.airspaceConstraintEditor.handleMapClick(movement.position);
        return;
      }
      if (options.flightPathWorkbench && options.flightPathWorkbench.isDrawing()) {
        options.flightPathWorkbench.handleMapClick(movement.position);
        return;
      }
      picked = viewer.scene.pick(movement.position);
      if (picked && picked.id && picked.id.type === 'flightObstacle') {
        if (options.flightObstacleLayer) options.flightObstacleLayer.selectObstacle(options.flightObstacleLayer.obstacleByIndex(picked.id.index));
        return;
      }
      if (!isPickedCitydbFeature(picked, options.buildingsTileset())) return;

      metadata = readPickedMetadata(picked);
      identifiers = getPickedIdentifiers(metadata);
      if (!identifiers.length) {
        options.renderFeatureError('已选中 3D Tiles 要素，但模型 metadata 中没有可用于查询 CityDB 的 id/objectid/identifier。');
        options.log('无法查询 CityDB：选中模型缺少 id metadata。');
        return;
      }

      requestToken = identifiers.join('|') + '|' + Date.now();
      selectedRequestToken = requestToken;
      options.renderFeatureLoading(identifiers[0], metadata);
      options.clearSelectedGridHighlight();
      options.log('已选中建筑模型，正在通过 PostgREST 查询 CityDB 属性与 GGER 包围网格。');

      Promise.all([
        options.requestCitydbFeature(identifiers, 0),
        options.requestCitydbGrid(identifiers, 0)
      ]).then(function (results) {
        var data = results[0];
        var gridData = results[1];
        if (selectedRequestToken !== requestToken) return;
        if (!data && gridData && gridData.feature) {
          data = { feature: gridData.feature, properties: [] };
        }
        if (!data) {
          options.renderFeatureError('CityDB 未找到对应要素。已尝试：' + identifiers.join(', '));
          options.log('CityDB 查询无结果：' + identifiers.join(', '));
          return;
        }
        if (gridData && gridData.grid) options.showSelectedGridHighlight(gridData);
        options.renderFeatureProperties(data, identifiers[0], gridData);
        options.log('CityDB 属性与 GGER 包围网格查询完成：' + (data.feature.objectid || data.feature.identifier || data.feature.id));
      }).catch(function (error) {
        if (selectedRequestToken !== requestToken) return;
        console.error('[Tianditu3D] CityDB RPC failed:', error);
        options.renderFeatureError('CityDB / GGER RPC 查询失败：' + error.message + '。请确认 PostgREST 服务与 RPC 函数可访问。');
        options.log('CityDB / GGER RPC 查询失败，请检查 PostgREST。');
      });
    }, CesiumRuntime.ScreenSpaceEventType.LEFT_CLICK);

    return handler;
  }

  global.HuaguoshanCitydbInspector = {
    escapeHtml: escapeHtml,
    formatPropertyValue: formatPropertyValue,
    showPanel: showPanel,
    hidePanel: hidePanel,
    featurePanel: featurePanel,
    renderFeatureMessage: renderFeatureMessage,
    renderFeatureLoading: renderFeatureLoading,
    renderFeatureError: renderFeatureError,
    renderGridCard: renderGridCard,
    renderFeatureProperties: renderFeatureProperties,
    getPickedPropertyIds: getPickedPropertyIds,
    getPickedProperty: getPickedProperty,
    readPickedMetadata: readPickedMetadata,
    metadataValue: metadataValue,
    getPickedIdentifiers: getPickedIdentifiers,
    isPickedCitydbFeature: isPickedCitydbFeature,
    flyToSelectedGridHighlight: flyToSelectedGridHighlight,
    bindFeaturePicking: bindFeaturePicking
  };
})(window);
