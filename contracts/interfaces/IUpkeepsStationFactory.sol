// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IUpkeepsStationFactory {
    event StationCreated(address indexed station);
    event StationDisabled(address indexed station);
    event UpkeepCreated(uint256 indexed id);
    event UpkeepCanceled(uint256 indexed id);
    event FactoryUpkeepRefueled(uint256 indexed id, uint96 indexed amount);
    event StationUpkeepRefueled(uint256 indexed id, uint96 indexed amount);
    event TransferredToStation(address indexed station, uint96 indexed amount);
    event RevokedFromStation(
        address indexed station,
        address[] indexed tokens,
        uint256[] indexed amount
    );

    function stations(uint256) external view returns (address);

    function factoryUpkeepId() external view returns (uint256);

    function minWaitNext() external view returns (uint256);

    function minStationBalance() external view returns (uint96);

    function minUpkeepBalance() external view returns (uint96);

    function toStationAmount() external view returns (uint96);

    function toUpkeepAmount() external view returns (uint96);

    function maxStationUpkeeps() external view returns (uint8);

    function getLessBusyStation() external view returns (address station);

    function getFlashBotUpkeepId(address _flashbot) external view returns (uint256);

    function setMinWaitNext(uint256 _interval) external;

    function setMinStationBalance(uint96 _minStationBalance) external;

    function setMinUpkeepBalance(uint96 _minUpkeepBalance) external;

    function setToStationAmount(uint96 _toStationAmount) external;

    function setToUpkeepAmount(uint96 _toUpkeepAmount) external;

    function selfDismantle() external;

    function withdrawStationFactoryUpkeep() external;

    function deployUpkeepsStation(
        string memory name,
        uint32 gasLimit,
        bytes calldata checkData,
        uint96 amount
    ) external;

    function disableUpkeepsStation(address _station, uint256 _index) external;

    function withdrawUpkeepsStation(address _station) external;

    function automateFlashBot(
        string memory name,
        address flashbot,
        uint32 gasLimit,
        bytes calldata checkData,
        uint96 amount
    ) external;

    function disableFlashBot(address _flashbot) external;

    function withdrawCanceledFlashBotUpkeeps(address _station, uint256 _upkeepsNumber) external;

    function withdrawAllCanceledFlashBotUpkeeps() external;
}
