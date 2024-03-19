pragma solidity ^0.8.18;

interface IAccount {
    function send(address _target, bytes calldata _data) external payable;

    function execute(address _target, bytes memory _data)
        external
        payable
        returns (bytes32);
}
