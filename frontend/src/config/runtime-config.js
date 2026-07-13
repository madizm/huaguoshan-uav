(function (global) {
  'use strict';

  global.HuaguoshanRuntimeConfig = {
    tianditu: {
      token: '2444f36b636d8eebf4c30ac7bc6c9347',
      url: 'https://t{s}.tianditu.gov.cn/',
      subdomains: ['0', '1', '2', '3', '4', '5', '6', '7']
    },
    tilesets: {
      citydb: '../exports/citydb-3dtiler/huaguoshan_3dtiles/tileset.json',
      lianyungangBuildings: '../exports/citydb-3dtiler/lianyungang_buildings_3dtiles/tileset.json',
      huaguoshanDem: '../exports/terrain/huaguoshan_dem_3dtiles/tileset.json',
      lianyungangDem: '../exports/terrain/lianyungang_dem_3dtiles/tileset.json',
      airspaceWg: {
        candidate: {
          '19': '../exports/airspace/wg_gger/candidate/level-19/tileset.json',
          '20': '../exports/airspace/wg_gger/candidate/level-20/tileset.json',
          '21': '../exports/airspace/wg_gger/candidate/level-21/tileset.json',
          '22': '../exports/airspace/wg_gger/candidate/level-22/tileset.json'
        },
        suitable: {
          '19': '../exports/airspace/wg_gger/suitable/level-19/tileset.json',
          '20': '../exports/airspace/wg_gger/suitable/level-20/tileset.json',
          '21': '../exports/airspace/wg_gger/suitable/level-21/tileset.json',
          '22': '../exports/airspace/wg_gger/suitable/level-22/tileset.json'
        }
      }
    },
    postgrest: {
      baseUrl: '/postgrest',
      jwtStorageKey: 'postgrest.jwt',
      airspaceProfile: 'api',
      suitableFootprintResource: 'suitable_fly_zone_footprints',
      airspaceTableByKind: {
        no_fly_zone: 'no_fly_zone',
        temp_control: 'temp_control_zone'
      }
    },
    auth: {
      loginUrl: '/auth/login',
      meUrl: '/auth/me',
      checkIntervalSeconds: 300
    },
    huaguoshan: {
      lon: 119.2683,
      lat: 34.6469
    },
    gridLayerColors: ['#5eead4', '#f6c85f', '#ff8f5f', '#8bd17c', '#80b7ff', '#c084fc', '#f472b6', '#67e8f9', '#facc15', '#a3e635']
  };
})(window);
