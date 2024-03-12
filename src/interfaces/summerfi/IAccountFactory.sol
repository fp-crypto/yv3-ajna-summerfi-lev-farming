pragma solidity 0.8.18;

interface IAccountFactory {
    function createAccount() external returns (address);

    function createAccount(address _user) external returns (address);
}
